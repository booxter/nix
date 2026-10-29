use std::fs::File;

use anyhow::Result;
use serde::Serialize;
use tempfile::TempDir;

use super::{classify, filter_dix_output, Classification, DiffBackend, NativeBackend};

const MIB: u64 = 1024 * 1024;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Package {
    path: String,
    nar_size: u64,
}

impl Package {
    fn new(hash: u8, name: &str, nar_size: u64) -> Self {
        Self {
            path: format!("/nix/store/{hash:032}-{name}"),
            nar_size,
        }
    }
}

#[derive(Clone, Serialize)]
struct Snapshot {
    version: u32,
    path: String,
    closure: Vec<Package>,
    selected: Vec<String>,
}

impl Snapshot {
    fn new(hash: u8, packages: Vec<Package>) -> Self {
        let root = Package::new(hash, "nixos-system-dix-test-1.0", 128);
        let selected = packages
            .iter()
            .map(|package| package.path.clone())
            .collect();
        let path = root.path.clone();
        let mut closure = packages;
        closure.push(root);

        Self {
            version: 1,
            path,
            closure,
            selected,
        }
    }
}

fn compare(old: &Snapshot, new: &Snapshot) -> Result<String> {
    let directory = TempDir::new()?;
    let old_path = directory.path().join("old.json");
    let new_path = directory.path().join("new.json");
    serde_json::to_writer(File::create(&old_path)?, old)?;
    serde_json::to_writer(File::create(&new_path)?, new)?;

    // Snapshots exercise the packaged executable without a daemon or host builds.
    // Use the production invocation and output filter, not a test command line.
    let output = NativeBackend.package_diff(&old_path, &new_path, "never")?;
    Ok(filter_dix_output(&output))
}

fn assert_classification(old: &Snapshot, new: &Snapshot, expected: Classification) -> String {
    let output = compare(old, new).expect("packaged dix must compare valid snapshots");
    assert!(
        !output.is_empty(),
        "a successful comparison must produce a report"
    );
    assert_eq!(classify(&output, 0), expected, "report:\n{output}");
    output
}

#[test]
fn packaged_dix_compares_identical_closures() {
    let snapshot = Snapshot::new(1, vec![Package::new(2, "example-1.0", MIB)]);

    assert_classification(&snapshot, &snapshot, Classification::Unchanged);
}

#[test]
fn packaged_dix_reports_size_only_changes_as_minor() {
    let old = Snapshot::new(1, vec![Package::new(2, "example-1.0", MIB)]);
    let new = Snapshot::new(3, vec![Package::new(4, "example-1.0", 3 * MIB)]);

    assert_classification(&old, &new, Classification::Minor);
}

#[test]
fn packaged_dix_reports_small_size_changes() {
    let old = Snapshot::new(1, vec![Package::new(2, "example-1.0", MIB)]);
    // Below the default 1 MiB display cutoff, but above dix's 8 KiB report floor.
    let new = Snapshot::new(3, vec![Package::new(4, "example-1.0", MIB + 64 * 1024)]);

    let output = assert_classification(&old, &new, Classification::Minor);
    assert!(
        output.contains("example"),
        "small package changes must be reported"
    );
}

#[test]
fn packaged_dix_reports_package_count_changes_as_major() {
    let package = Package::new(2, "example-1.0", 128);
    let old = Snapshot::new(1, vec![package.clone()]);
    let new = Snapshot::new(3, vec![package, Package::new(4, "example-1.0", 128)]);

    let output = assert_classification(&old, &new, Classification::Major);
    assert!(
        output.contains("example"),
        "the additional package must be reported"
    );
}

#[test]
fn packaged_dix_reports_an_upgrade_as_major() {
    let old = Snapshot::new(1, vec![Package::new(2, "example-1.0", MIB)]);
    let new = Snapshot::new(3, vec![Package::new(4, "example-2.0", MIB)]);

    let output = assert_classification(&old, &new, Classification::Major);
    let upgrade = output
        .lines()
        .find(|line| line.contains("example"))
        .expect("the upgraded package must appear in the report");
    assert!(
        upgrade.contains("1.0") && upgrade.contains("2.0"),
        "{upgrade}"
    );
}

#[test]
fn packaged_dix_reports_an_added_package_as_major() {
    let old = Snapshot::new(1, Vec::new());
    let new = Snapshot::new(3, vec![Package::new(4, "example-1.0", MIB)]);

    let output = assert_classification(&old, &new, Classification::Major);
    assert!(
        output.contains("example"),
        "the added package must be reported"
    );
}

#[test]
fn packaged_dix_reports_a_removed_package_as_major() {
    let old = Snapshot::new(1, vec![Package::new(2, "example-1.0", MIB)]);
    let new = Snapshot::new(3, Vec::new());

    let output = assert_classification(&old, &new, Classification::Major);
    assert!(
        output.contains("example"),
        "the removed package must be reported"
    );
}

#[test]
fn generated_config_changes_are_major_with_an_unchanged_closure() {
    let snapshot = Snapshot::new(1, vec![Package::new(2, "example-1.0", MIB)]);
    let mut output = compare(&snapshot, &snapshot).expect("compare identical closures");
    output.push_str("--- old/etc/config\n+++ new/etc/config\n@@ -1 +1 @@\n-before\n+after\n");

    assert_eq!(
        classify(&output, 0),
        Classification::Major,
        "report:\n{output}"
    );
}

#[test]
fn packaged_dix_rejects_an_unsupported_snapshot() {
    let old = Snapshot::new(1, vec![Package::new(2, "example-1.0", MIB)]);
    let mut invalid = old.clone();
    invalid.version = u32::MAX;

    let error = compare(&old, &invalid).expect_err("invalid snapshots must fail");
    let diagnostic = format!("{error:#}");
    assert!(diagnostic.contains("snapshot"), "{diagnostic}");
    assert_eq!(classify("", 1), Classification::Error);
}
