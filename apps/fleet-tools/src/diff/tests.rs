use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use super::{
    copy_generated_path, filter_binary_diff_output, filter_dix_output,
    materialize_homebrew_revision, normalize_store_paths, run_with_backend, DiffBackend,
    DiffOptions, GeneratedPath, GitCheckout, HomebrewManifest, RecursiveDiff, Revision,
    RevisionSide, TargetKind, TargetRequest,
};

struct FakeBackend {
    old_kind: Option<TargetKind>,
    new_kind: Option<TargetKind>,
    builds: RefCell<Vec<(RevisionSide, TargetKind)>>,
    package_diff: String,
    details: bool,
    fixture: TempDir,
    recursive_diff_called: Cell<bool>,
}

impl FakeBackend {
    fn new(kind: TargetKind, details: bool) -> Self {
        let fixture = TempDir::new().expect("backend fixture");
        if details {
            for side in [RevisionSide::Old, RevisionSide::New] {
                let label = side.label();
                fs::write(
                    fixture.path().join(format!("nginx-{label}.conf")),
                    format!("nginx={label}\n"),
                )
                .expect("nginx fixture");
                let activation = fixture.path().join(format!("activation-{label}"));
                fs::create_dir_all(activation.join("home-files/.config"))
                    .expect("Home Manager fixture");
                fs::write(activation.join("activate"), format!("activate={label}\n"))
                    .expect("activation script");
                fs::write(
                    activation.join("home-files/.config/hm.conf"),
                    format!("home={label}\n"),
                )
                .expect("Home Manager config");
                let session = fixture.path().join(format!("session-{label}"));
                fs::create_dir_all(session.join("etc/profile.d")).expect("session fixture");
                fs::write(
                    session.join("etc/profile.d/hm-session-vars.sh"),
                    format!("session={label}\n"),
                )
                .expect("session variables");
            }
        }
        Self {
            old_kind: Some(kind),
            new_kind: Some(kind),
            builds: RefCell::new(Vec::new()),
            package_diff: concat!(
                "<<< old\n",
                ">>> new\n",
                "[C.] source +1\n",
                "[U.] package 1 -> 2\n"
            )
            .to_owned(),
            details,
            fixture,
            recursive_diff_called: Cell::new(false),
        }
    }
}

impl DiffBackend for FakeBackend {
    fn detect_target(&self, revision: &Revision) -> anyhow::Result<Option<TargetKind>> {
        Ok(match revision.side {
            RevisionSide::Old => self.old_kind,
            RevisionSide::New => self.new_kind,
        })
    }

    fn build_toplevel(
        &self,
        kind: TargetKind,
        revision: &Revision,
        out_link: &Path,
    ) -> anyhow::Result<()> {
        self.builds.borrow_mut().push((revision.side, kind));
        if self.details {
            fs::create_dir_all(out_link.join("etc/nix"))?;
            fs::create_dir_all(out_link.join("bin"))?;
            let hash = match revision.side {
                RevisionSide::Old => "11111111111111111111111111111111",
                RevisionSide::New => "22222222222222222222222222222222",
            };
            fs::write(
                out_link.join("etc/nix/nix.conf"),
                format!("store=/nix/store/{hash}-same-package/bin\n"),
            )?;
            fs::write(out_link.join("etc/issue"), "release metadata\n")?;
            fs::write(out_link.join("activate"), format!("activate={hash}\n"))?;
            fs::write(
                out_link.join("bin/switch-to-configuration"),
                format!("switch={hash}\n"),
            )?;
        }
        Ok(())
    }

    fn package_diff(
        &self,
        _old_link: &Path,
        _new_link: &Path,
        _color: &str,
    ) -> anyhow::Result<String> {
        Ok(self.package_diff.clone())
    }

    fn nginx_config(&self, revision: &Revision) -> anyhow::Result<Option<PathBuf>> {
        Ok(self.details.then(|| {
            self.fixture
                .path()
                .join(format!("nginx-{}.conf", revision.side.label()))
        }))
    }

    fn home_manager_users(
        &self,
        _kind: TargetKind,
        _revision: &Revision,
    ) -> anyhow::Result<Vec<String>> {
        Ok(if self.details {
            vec!["ihrachyshka".to_owned()]
        } else {
            Vec::new()
        })
    }

    fn home_manager_package(
        &self,
        _kind: TargetKind,
        revision: &Revision,
        _user: &str,
        attribute: &str,
    ) -> anyhow::Result<PathBuf> {
        let prefix = match attribute {
            "activationPackage" => "activation",
            "sessionVariablesPackage" => "session",
            _ => anyhow::bail!("unexpected Home Manager attribute: {attribute}"),
        };
        Ok(self
            .fixture
            .path()
            .join(format!("{prefix}-{}", revision.side.label())))
    }

    fn homebrew_manifest(&self, _revision: &Revision) -> anyhow::Result<HomebrewManifest> {
        Ok(HomebrewManifest::default())
    }

    fn recursive_diff(&self, root: &Path, _color: Option<&str>) -> anyhow::Result<RecursiveDiff> {
        self.recursive_diff_called.set(true);
        assert_eq!(
            fs::read_to_string(root.join("old/system/etc/nix/nix.conf"))?,
            "store=/nix/store/<path>/bin\n"
        );
        assert!(!root.join("old/system/etc/issue").exists());
        assert_eq!(
            fs::read_to_string(root.join("new/system/services/nginx.conf"))?,
            "nginx=new\n"
        );
        assert_eq!(
            fs::read_to_string(
                root.join("old/home-manager/ihrachyshka/home-files/.config/hm.conf")
            )?,
            "home=old\n"
        );
        assert_eq!(
            fs::read_to_string(root.join(
                "new/home-manager/ihrachyshka/session-vars/etc/profile.d/hm-session-vars.sh"
            ))?,
            "session=new\n"
        );
        Ok(RecursiveDiff::Different("detail output\n".to_owned()))
    }
}

fn test_checkout() -> (TempDir, GitCheckout, String, String) {
    let directory = TempDir::new().expect("temporary repository");
    fs::write(directory.path().join("flake.nix"), "{}\n").expect("flake marker");
    let repository = gix::init(directory.path()).expect("initialize repository");
    let signature =
        gix::actor::SignatureRef::from_bytes(b"Test User <test@example.invalid> 1700000000 +0000")
            .expect("valid signature");
    let tree = repository.empty_tree().id;
    let old = repository
        .commit_as(
            signature,
            signature,
            "HEAD",
            "old",
            tree,
            std::iter::empty::<gix::ObjectId>(),
        )
        .expect("create old commit")
        .detach();
    let new = repository
        .commit_as(signature, signature, "HEAD", "new", tree, [old])
        .expect("create new commit")
        .detach();
    drop(repository);
    let checkout = GitCheckout::discover(Some(directory.path())).expect("discover checkout");
    (directory, checkout, old.to_string(), new.to_string())
}

#[test]
fn target_parser_accepts_short_and_flake_attribute_names() {
    assert_eq!(
        "frame".parse::<TargetRequest>().expect("short target"),
        TargetRequest {
            machine: "frame".to_owned(),
            explicit_kind: None,
        }
    );
    assert_eq!(
        ".#nixosConfigurations.frame.config.system.build.toplevel"
            .parse::<TargetRequest>()
            .expect("NixOS attribute"),
        TargetRequest {
            machine: "frame".to_owned(),
            explicit_kind: Some(TargetKind::Nixos),
        }
    );
    assert_eq!(
        "#darwinConfigurations.mair.system"
            .parse::<TargetRequest>()
            .expect("Darwin attribute"),
        TargetRequest {
            machine: "mair".to_owned(),
            explicit_kind: Some(TargetKind::Darwin),
        }
    );
}

#[test]
fn workflow_builds_both_revisions_and_filters_package_diff() {
    let (_directory, checkout, old, new) = test_checkout();
    let backend = FakeBackend::new(TargetKind::Nixos, false);
    let options = DiffOptions {
        details: false,
        generated_paths: Vec::new(),
        target: "frame".parse().expect("known target"),
        old_revision: old,
        new_revision: new,
    };
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();

    run_with_backend(&options, &checkout, &backend, &mut stdout, &mut stderr)
        .expect("run configuration diff");

    assert_eq!(
        backend.builds.into_inner(),
        [
            (RevisionSide::Old, TargetKind::Nixos),
            (RevisionSide::New, TargetKind::Nixos),
        ]
    );
    assert_eq!(
        String::from_utf8(stdout).expect("UTF-8 output"),
        "[U.] package 1 -> 2\n"
    );
    let stderr = String::from_utf8(stderr).expect("UTF-8 diagnostics");
    assert!(stderr.contains("Building nixos configuration frame at old"));
    assert!(stderr.contains("Building nixos configuration frame at new"));
    assert!(stderr.contains("Diffing nixos configuration frame:"));
}

#[test]
fn workflow_reports_new_only_machine_without_building() {
    let (_directory, checkout, old, new) = test_checkout();
    let mut backend = FakeBackend::new(TargetKind::Nixos, false);
    backend.old_kind = None;
    let options = DiffOptions {
        details: false,
        generated_paths: Vec::new(),
        target: "frame".parse().expect("known target"),
        old_revision: old,
        new_revision: new,
    };
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();

    run_with_backend(&options, &checkout, &backend, &mut stdout, &mut stderr)
        .expect("report new-only target");

    assert!(backend.builds.into_inner().is_empty());
    assert_eq!(
        String::from_utf8(stdout).expect("UTF-8 output"),
        "Machine 'frame' is present only in the new revision; no old configuration exists to diff.\n"
    );
    assert!(stderr.is_empty());
}

#[test]
fn workflow_detects_bare_darwin_target() {
    let (_directory, checkout, old, new) = test_checkout();
    let backend = FakeBackend::new(TargetKind::Darwin, false);
    let options = DiffOptions {
        details: false,
        generated_paths: Vec::new(),
        target: "mair".parse().expect("known target"),
        old_revision: old,
        new_revision: new,
    };

    run_with_backend(
        &options,
        &checkout,
        &backend,
        &mut Vec::new(),
        &mut Vec::new(),
    )
    .expect("run Darwin diff");

    assert_eq!(
        backend.builds.into_inner(),
        [
            (RevisionSide::Old, TargetKind::Darwin),
            (RevisionSide::New, TargetKind::Darwin),
        ]
    );
}

#[test]
fn detailed_workflow_materializes_system_nginx_and_home_manager_data() {
    let (_directory, checkout, old, new) = test_checkout();
    let backend = FakeBackend::new(TargetKind::Nixos, true);
    let options = DiffOptions {
        details: true,
        generated_paths: Vec::new(),
        target: "frame".parse().expect("known target"),
        old_revision: old,
        new_revision: new,
    };
    let mut stdout = Vec::new();

    run_with_backend(&options, &checkout, &backend, &mut stdout, &mut Vec::new())
        .expect("run detailed diff");

    assert!(backend.recursive_diff_called.get());
    assert_eq!(
        String::from_utf8(stdout).expect("UTF-8 output"),
        "[U.] package 1 -> 2\ndetail output\n"
    );
}

#[test]
fn generated_paths_reject_absolute_and_parent_components() {
    for path in ["", "/etc", "..", "../etc", "etc/../secret"] {
        assert!(path.parse::<GeneratedPath>().is_err(), "accepted {path:?}");
    }
    assert_eq!(
        "etc/nix/nix.conf"
            .parse::<GeneratedPath>()
            .expect("relative path")
            .as_path(),
        Path::new("etc/nix/nix.conf")
    );
}

#[test]
fn native_git_checkout_resolves_commits_without_git_cli() {
    let directory = TempDir::new().expect("temporary repository");
    fs::write(directory.path().join("flake.nix"), "{}\n").expect("flake marker");
    let repository = gix::init(directory.path()).expect("initialize repository");
    let signature =
        gix::actor::SignatureRef::from_bytes(b"Test User <test@example.invalid> 1700000000 +0000")
            .expect("valid signature");
    let commit = repository
        .commit_as(
            signature,
            signature,
            "HEAD",
            "initial",
            repository.empty_tree().id,
            std::iter::empty::<gix::ObjectId>(),
        )
        .expect("create commit")
        .detach();
    drop(repository);

    let checkout = GitCheckout::discover(Some(directory.path())).expect("discover checkout");
    assert_eq!(
        checkout
            .resolve_revision("new", "HEAD")
            .expect("resolve HEAD"),
        commit.to_string()
    );
    assert_eq!(
        checkout.flake_ref(&commit.to_string()),
        format!(
            "git+file://{}?rev={commit}",
            directory
                .path()
                .canonicalize()
                .expect("canonical path")
                .display()
        )
    );
    assert!(checkout.resolve_revision("old", "missing").is_err());
}

#[test]
fn dix_filter_removes_headers_and_redundant_packages() {
    let output = concat!(
        "<<< /tmp/old\n",
        ">>> /tmp/new\n",
        "\n",
        "CHANGED\n",
        "[C.] source +14.8 KiB\n",
        "\u{1b}[31m[C.]\u{1b}[0m \u{1b}[32msource\u{1b}[0m +14.8 KiB\n",
        "[U.] nixos-system-frame 1 -> 2\n",
        "[U.] package 1.0 -> 2.0\n",
        "\n",
        "SIZE: 1 -> 2\n",
    );

    assert_eq!(
        filter_dix_output(output),
        "CHANGED\n[U.] package 1.0 -> 2.0\n\nSIZE: 1 -> 2\n"
    );
}

#[test]
fn store_paths_are_normalized_in_plain_and_roff_text() {
    let hash = "11111111111111111111111111111111";
    assert_eq!(
        normalize_store_paths(&format!(
            "plain=/nix/store/{hash}-same-package/bin roff=/nix/store/{hash}\\-source/modules\n"
        )),
        "plain=/nix/store/<path>/bin roff=/nix/store/<path>/modules\n"
    );
}

#[test]
fn generated_tree_copy_normalizes_text_and_skips_package_noise() {
    let source = TempDir::new().expect("source tree");
    let destination = TempDir::new().expect("destination tree");
    let etc = source.path().join("etc");
    fs::create_dir_all(etc.join("nix")).expect("nix directory");
    fs::create_dir_all(etc.join("ssl/certs")).expect("certificate directory");
    fs::create_dir_all(etc.join("test-links")).expect("link directory");
    let config = etc.join("nix/nix.conf");
    fs::write(
        &config,
        "store=/nix/store/11111111111111111111111111111111-same-package/bin\n",
    )
    .expect("config");
    fs::set_permissions(&config, fs::Permissions::from_mode(0o444)).expect("readonly config");
    fs::write(etc.join("issue"), "release metadata\n").expect("issue");
    fs::write(
        etc.join("ssl/certs/ca-bundle.crt"),
        "generated certificates\n",
    )
    .expect("certificate bundle");
    fs::write(etc.join("test-links/cache.bin"), b"\0binary\n").expect("binary file");
    symlink("missing-target", etc.join("test-links/broken")).expect("broken symlink");

    copy_generated_path(source.path(), destination.path(), Path::new("etc"))
        .expect("copy generated tree");

    assert_eq!(
        fs::read_to_string(destination.path().join("etc/nix/nix.conf")).expect("normalized config"),
        "store=/nix/store/<path>/bin\n"
    );
    assert!(
        fs::metadata(destination.path().join("etc/nix/nix.conf"))
            .expect("config metadata")
            .permissions()
            .mode()
            & 0o200
            != 0
    );
    assert!(!destination.path().join("etc/issue").exists());
    assert!(!destination
        .path()
        .join("etc/ssl/certs/ca-bundle.crt")
        .exists());
    assert_eq!(
        fs::read(destination.path().join("etc/test-links/cache.bin")).expect("binary copy"),
        b"\0binary\n"
    );
    assert_eq!(
        fs::read_to_string(destination.path().join("etc/test-links/broken"))
            .expect("broken link marker"),
        "broken symlink -> missing-target\n"
    );
}

#[test]
fn homebrew_materialization_uses_typed_manifest_and_tap_layout() {
    let tap = TempDir::new().expect("tap");
    let destination = TempDir::new().expect("destination");
    fs::create_dir_all(tap.path().join("Casks/s")).expect("cask directory");
    fs::write(
        tap.path().join("Casks/s/sf-symbols.rb"),
        "cask \"sf-symbols\" do\n  version \"8.0\"\nend\n",
    )
    .expect("cask recipe");
    let manifest = HomebrewManifest {
        enabled: true,
        casks: vec!["sf-symbols".to_owned()],
        taps: BTreeMap::from([("homebrew/homebrew-cask".to_owned(), tap.path().to_owned())]),
        ..HomebrewManifest::default()
    };
    let mut stderr = Vec::new();

    assert!(
        materialize_homebrew_revision(&manifest, destination.path(), &mut stderr)
            .expect("materialize cask")
    );
    assert!(stderr.is_empty());
    assert_eq!(
        fs::read_to_string(destination.path().join("homebrew/casks/sf-symbols.rb"))
            .expect("materialized recipe"),
        "cask \"sf-symbols\" do\n  version \"8.0\"\nend\n"
    );
}

#[test]
fn binary_diff_lines_are_removed_without_hiding_text_changes() {
    assert_eq!(
        filter_binary_diff_output(
            "diff -ruN old/a new/a\nBinary files old/cache and new/cache differ\n-old\n+new\n"
        ),
        "diff -ruN old/a new/a\n-old\n+new\n"
    );
}

#[test]
fn homebrew_tokens_reject_traversal_instead_of_writing_outside_tree() {
    let destination = TempDir::new().expect("destination");
    let manifest = HomebrewManifest {
        enabled: true,
        brews: vec!["../escape".to_owned()],
        ..HomebrewManifest::default()
    };
    let mut stderr = Vec::new();

    assert!(
        !materialize_homebrew_revision(&manifest, destination.path(), &mut stderr)
            .expect("skip invalid token")
    );
    assert!(String::from_utf8(stderr)
        .expect("UTF-8 diagnostic")
        .contains("Skipping invalid Homebrew brew token '../escape'."));
    assert!(!destination.path().join("escape.rb").exists());
}

#[test]
fn canonical_homebrew_tap_names_drop_repository_prefix() {
    assert_eq!(
        super::canonical_tap("homebrew/homebrew-cask"),
        "homebrew/cask"
    );
    assert_eq!(super::canonical_tap("owner/custom"), "owner/custom");
}

#[test]
fn recursive_recipe_search_is_deterministic() {
    let root = TempDir::new().expect("tap");
    fs::create_dir_all(root.path().join("Formula/z/deep")).expect("nested directory");
    let expected = root.path().join("Formula/z/deep/tool.rb");
    fs::write(&expected, "formula\n").expect("recipe");
    let manifest = HomebrewManifest {
        taps: BTreeMap::from([("owner/tap".to_owned(), root.path().to_owned())]),
        ..HomebrewManifest::default()
    };

    assert_eq!(
        super::find_recipe(&manifest, "brew", "tool", None),
        Some(expected)
    );
}
