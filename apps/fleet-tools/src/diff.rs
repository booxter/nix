use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};

use anyhow::{bail, Context, Result};
use tempfile::TempDir;

use crate::HostInventory;

mod backend;
mod revision;
mod target;

use backend::{DiffBackend, HomebrewManifest, NativeBackend, RecursiveDiff};
use revision::{GitCheckout, Revision, RevisionSide};
pub use target::{DiffOptions, GeneratedPath, TargetKind, TargetRequest};

const TARGET_ALIASES_JSON: &str = env!("DIFF_TARGET_ALIASES_JSON");

struct BuildWorkspace {
    directory: Option<TempDir>,
    keep: bool,
}

impl BuildWorkspace {
    fn new() -> Result<Self> {
        Ok(Self {
            directory: Some(tempfile::Builder::new().prefix("diff-config.").tempdir()?),
            keep: env::var("DIFF_CONFIG_KEEP_TMP").is_ok_and(|value| value == "1"),
        })
    }

    fn path(&self) -> &Path {
        self.directory
            .as_ref()
            .expect("workspace is present")
            .path()
    }
}

impl Drop for BuildWorkspace {
    fn drop(&mut self) {
        if self.keep {
            if let Some(directory) = self.directory.take() {
                let path = directory.keep();
                eprintln!("Keeping temporary output links in {}", path.display());
            }
        }
    }
}

pub fn execute(options: &DiffOptions) -> Result<()> {
    let explicit_root = env::var_os("DIFF_CONFIG_REPO_ROOT").map(PathBuf::from);
    let checkout = GitCheckout::discover(explicit_root.as_deref())?;
    let backend = NativeBackend;
    run_with_backend(
        options,
        &checkout,
        &backend,
        &mut io::stdout().lock(),
        &mut io::stderr().lock(),
    )
}

fn run_with_backend(
    options: &DiffOptions,
    checkout: &GitCheckout,
    backend: &impl DiffBackend,
    stdout: &mut impl Write,
    stderr: &mut impl Write,
) -> Result<()> {
    let mut target = options.target.clone();
    resolve_known_target(&mut target)?;

    let old_id = checkout.resolve_revision("old", &options.old_revision)?;
    let new_id = checkout.resolve_revision("new", &options.new_revision)?;
    let old = Revision {
        side: RevisionSide::Old,
        flake_ref: checkout.flake_ref(&old_id),
        id: old_id,
        machine: target.machine.clone(),
    };
    let new = Revision {
        side: RevisionSide::New,
        flake_ref: checkout.flake_ref(&new_id),
        id: new_id,
        machine: target.machine.clone(),
    };

    let old_kind = matching_kind(backend.detect_target(&old)?, target.explicit_kind);
    let new_kind = matching_kind(backend.detect_target(&new)?, target.explicit_kind);
    let kind = match (old_kind, new_kind) {
        (None, Some(_)) => {
            writeln!(
                stdout,
                "Machine '{}' is present only in the new revision; no old configuration exists to diff.",
                target.machine
            )?;
            return Ok(());
        }
        (Some(_), None) => {
            writeln!(
                stdout,
                "Machine '{}' is present only in the old revision; no new configuration exists to diff.",
                target.machine
            )?;
            return Ok(());
        }
        (None, None) => bail!("Machine '{}' must exist in at least one revision.", target.machine),
        (Some(old_kind), Some(new_kind)) if old_kind != new_kind => bail!(
            "Machine '{}' changed configuration kind between revisions.\nold revision: {old_kind}; new revision: {new_kind}",
            target.machine
        ),
        (Some(kind), Some(_)) => kind,
    };

    let generated_paths = if options.details {
        if options.generated_paths.is_empty() {
            default_generated_paths(kind)
        } else {
            options.generated_paths.clone()
        }
    } else {
        Vec::new()
    };

    let workspace = BuildWorkspace::new()?;
    let old_link = workspace.path().join("old");
    let new_link = workspace.path().join("new");
    build_revision(backend, kind, &old, &old_link, stderr)?;
    build_revision(backend, kind, &new, &new_link, stderr)?;

    writeln!(
        stderr,
        "Diffing {kind} configuration {}: {} -> {}",
        target.machine, old.id, new.id
    )?;
    let dix_color = env::var("DIFF_CONFIG_DIX_COLOR").unwrap_or_else(|_| {
        if io::stdout().is_terminal() {
            "always".to_owned()
        } else {
            "auto".to_owned()
        }
    });
    stdout.write_all(
        filter_dix_output(&backend.package_diff(&old_link, &new_link, &dix_color)?).as_bytes(),
    )?;

    if options.details {
        let color = env::var("DIFF_CONFIG_DIFF_COLOR")
            .ok()
            .or_else(|| io::stdout().is_terminal().then(|| "always".to_owned()));
        run_detail_diff(
            backend,
            kind,
            &old,
            &new,
            &old_link,
            &new_link,
            &generated_paths,
            workspace.path(),
            color.as_deref(),
            stdout,
            stderr,
        )?;
    }
    Ok(())
}

fn matching_kind(found: Option<TargetKind>, requested: Option<TargetKind>) -> Option<TargetKind> {
    found.filter(|kind| requested.is_none_or(|requested| requested == *kind))
}

fn resolve_known_target(target: &mut TargetRequest) -> Result<()> {
    let inventory = crate::compiled_inventory().context("Compiled fleet inventory is invalid")?;
    let aliases: BTreeMap<String, String> =
        serde_json::from_str(TARGET_ALIASES_JSON).context("Compiled target aliases are invalid")?;
    if !known_machine(&inventory, &aliases, &target.machine) {
        bail!("Unknown machine: {}", target.machine);
    }
    if target.explicit_kind != Some(TargetKind::Darwin) {
        if let Some(resolved) = aliases.get(&target.machine) {
            target.machine.clone_from(resolved);
        }
    }
    Ok(())
}

fn known_machine(
    inventory: &HostInventory,
    aliases: &BTreeMap<String, String>,
    machine: &str,
) -> bool {
    inventory.darwin.contains_key(machine)
        || inventory.nixos.contains_key(machine)
        || aliases.contains_key(machine)
}

fn build_revision(
    backend: &impl DiffBackend,
    kind: TargetKind,
    revision: &Revision,
    out_link: &Path,
    stderr: &mut impl Write,
) -> Result<()> {
    writeln!(
        stderr,
        "Building {kind} configuration {} at {} ({})",
        revision.machine,
        revision.side.label(),
        revision.id
    )?;
    backend.build_toplevel(kind, revision, out_link)
}

fn default_generated_paths(kind: TargetKind) -> Vec<GeneratedPath> {
    let paths: &[&str] = match kind {
        TargetKind::Nixos => &["etc"],
        TargetKind::Darwin => &[
            "etc",
            "Library/LaunchAgents",
            "Library/LaunchDaemons",
            "user/Library/LaunchAgents",
        ],
    };
    paths
        .iter()
        .map(|path| path.parse().expect("default paths are valid"))
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn run_detail_diff(
    backend: &impl DiffBackend,
    kind: TargetKind,
    old: &Revision,
    new: &Revision,
    old_link: &Path,
    new_link: &Path,
    generated_paths: &[GeneratedPath],
    workspace: &Path,
    color: Option<&str>,
    stdout: &mut impl Write,
    stderr: &mut impl Write,
) -> Result<()> {
    let root = workspace.join("details");
    let old_root = root.join("old");
    let new_root = root.join("new");
    fs::create_dir_all(&old_root)?;
    fs::create_dir_all(&new_root)?;

    let mut found = materialize_system_details(
        kind,
        old_link,
        new_link,
        generated_paths,
        &old_root,
        &new_root,
        stderr,
    )?;
    found |= materialize_nginx_details(backend, kind, old, new, &old_root, &new_root)?;
    found |= materialize_homebrew_details(backend, kind, old, new, &old_root, &new_root, stderr)?;
    found |=
        materialize_home_manager_details(backend, kind, old, new, &old_root, &new_root, stderr)?;

    if !found {
        bail!("No generated detail paths found.");
    }

    match backend.recursive_diff(&root, color)? {
        RecursiveDiff::Identical => writeln!(stdout, "No generated config differences.")?,
        RecursiveDiff::Different(output) => stdout.write_all(output.as_bytes())?,
    }
    Ok(())
}

fn materialize_system_details(
    kind: TargetKind,
    old_link: &Path,
    new_link: &Path,
    generated_paths: &[GeneratedPath],
    old_root: &Path,
    new_root: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    let artifacts: &[&str] = match kind {
        TargetKind::Nixos => &["activate", "bin/switch-to-configuration"],
        TargetKind::Darwin => &["activate", "activate-user"],
    };
    let mut found = false;
    for generated in generated_paths {
        if path_exists(&old_link.join(generated.as_path()))
            || path_exists(&new_link.join(generated.as_path()))
        {
            found = true;
        } else {
            writeln!(
                stderr,
                "Skipping missing generated path in both revisions: {generated}"
            )?;
        }
    }
    found |= artifacts
        .iter()
        .any(|path| path_exists(&old_link.join(path)) || path_exists(&new_link.join(path)));
    if !found {
        return Ok(false);
    }

    let old_system = old_root.join("system");
    let new_system = new_root.join("system");
    fs::create_dir_all(&old_system)?;
    fs::create_dir_all(&new_system)?;
    for generated in generated_paths {
        copy_generated_path(old_link, &old_system, generated.as_path())?;
        copy_generated_path(new_link, &new_system, generated.as_path())?;
    }
    for artifact in artifacts {
        copy_generated_path(old_link, &old_system, Path::new(artifact))?;
        copy_generated_path(new_link, &new_system, Path::new(artifact))?;
    }
    Ok(true)
}

fn materialize_nginx_details(
    backend: &impl DiffBackend,
    kind: TargetKind,
    old: &Revision,
    new: &Revision,
    old_root: &Path,
    new_root: &Path,
) -> Result<bool> {
    if kind != TargetKind::Nixos {
        return Ok(false);
    }
    let old_config = backend.nginx_config(old)?;
    let new_config = backend.nginx_config(new)?;
    if let Some(path) = &old_config {
        copy_store_path(
            path,
            &old_root.join("system"),
            Path::new("services/nginx.conf"),
        )?;
    }
    if let Some(path) = &new_config {
        copy_store_path(
            path,
            &new_root.join("system"),
            Path::new("services/nginx.conf"),
        )?;
    }
    Ok(old_config.is_some() || new_config.is_some())
}

fn materialize_home_manager_details(
    backend: &impl DiffBackend,
    kind: TargetKind,
    old: &Revision,
    new: &Revision,
    old_root: &Path,
    new_root: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    let old_users: BTreeSet<String> = backend.home_manager_users(kind, old)?.into_iter().collect();
    let new_users: BTreeSet<String> = backend.home_manager_users(kind, new)?.into_iter().collect();
    let users: BTreeSet<&String> = old_users.union(&new_users).collect();
    if users.is_empty() {
        return Ok(false);
    }

    for user in users {
        let old_tree = old_root.join("home-manager").join(user);
        let new_tree = new_root.join("home-manager").join(user);
        fs::create_dir_all(&old_tree)?;
        fs::create_dir_all(&new_tree)?;

        if old_users.contains(user) {
            materialize_home_manager_user(backend, kind, old, user, &old_tree)?;
        } else {
            writeln!(
                stderr,
                "Home Manager user {user} is missing in old revision; diffing against an empty tree."
            )?;
        }
        if new_users.contains(user) {
            materialize_home_manager_user(backend, kind, new, user, &new_tree)?;
        } else {
            writeln!(
                stderr,
                "Home Manager user {user} is missing in new revision; diffing against an empty tree."
            )?;
        }
    }
    Ok(true)
}

fn materialize_home_manager_user(
    backend: &impl DiffBackend,
    kind: TargetKind,
    revision: &Revision,
    user: &str,
    destination: &Path,
) -> Result<()> {
    let activation = backend.home_manager_package(kind, revision, user, "activationPackage")?;
    for path in ["activate", "home-files", "LaunchAgents"] {
        copy_generated_path(&activation, destination, Path::new(path))?;
    }
    let session = backend.home_manager_package(kind, revision, user, "sessionVariablesPackage")?;
    copy_store_path(&session, destination, Path::new("session-vars"))
}

fn materialize_homebrew_details(
    backend: &impl DiffBackend,
    kind: TargetKind,
    old: &Revision,
    new: &Revision,
    old_root: &Path,
    new_root: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    if kind != TargetKind::Darwin {
        return Ok(false);
    }
    let old_found =
        materialize_homebrew_revision(&backend.homebrew_manifest(old)?, old_root, stderr)?;
    let new_found =
        materialize_homebrew_revision(&backend.homebrew_manifest(new)?, new_root, stderr)?;
    Ok(old_found || new_found)
}

fn materialize_homebrew_revision(
    manifest: &HomebrewManifest,
    destination: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    if !manifest.enabled {
        return Ok(false);
    }
    let mut found = false;
    for token in &manifest.brews {
        found |= materialize_homebrew_recipe(manifest, "brew", token, destination, stderr)?;
    }
    for token in &manifest.casks {
        found |= materialize_homebrew_recipe(manifest, "cask", token, destination, stderr)?;
    }
    Ok(found)
}

fn materialize_homebrew_recipe(
    manifest: &HomebrewManifest,
    kind: &str,
    token: &str,
    destination: &Path,
    stderr: &mut impl Write,
) -> Result<bool> {
    if !valid_homebrew_token(token) {
        writeln!(stderr, "Skipping invalid Homebrew {kind} token '{token}'.")?;
        return Ok(false);
    }
    let recipe = token.rsplit('/').next().expect("token is nonempty");
    let qualified_tap = (token.matches('/').count() >= 2)
        .then(|| token.rsplit_once('/').expect("qualified token").0);
    let preferred_tap = match (qualified_tap, kind) {
        (Some(tap), _) => Some(tap),
        (None, "cask") => Some("homebrew/cask"),
        (None, "brew") => Some("homebrew/core"),
        _ => None,
    };

    let recipe_path = find_recipe(manifest, kind, recipe, preferred_tap)
        .or_else(|| preferred_tap.and_then(|_| find_recipe(manifest, kind, recipe, None)));
    let Some(recipe_path) = recipe_path else {
        writeln!(
            stderr,
            "Unable to find Homebrew {kind} recipe '{token}' in Nix-managed taps."
        )?;
        return Ok(false);
    };
    let destination = destination
        .join("homebrew")
        .join(format!("{kind}s"))
        .join(format!("{token}.rb"));
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(recipe_path, destination)?;
    Ok(true)
}

fn find_recipe(
    manifest: &HomebrewManifest,
    kind: &str,
    recipe: &str,
    required_tap: Option<&str>,
) -> Option<PathBuf> {
    let directory = match kind {
        "brew" => "Formula",
        "cask" => "Casks",
        _ => return None,
    };
    for (tap, root) in &manifest.taps {
        if required_tap.is_some_and(|required| canonical_tap(tap) != required) {
            continue;
        }
        let root = root.join(directory);
        for candidate in [
            root.join(recipe.chars().next()?.to_string())
                .join(format!("{recipe}.rb")),
            root.join(format!("{recipe}.rb")),
        ] {
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        if let Some(candidate) = find_file_recursive(&root, &format!("{recipe}.rb")) {
            return Some(candidate);
        }
    }
    None
}

fn canonical_tap(tap: &str) -> String {
    let Some((owner, repository)) = tap.split_once('/') else {
        return tap.to_owned();
    };
    format!(
        "{owner}/{}",
        repository.strip_prefix("homebrew-").unwrap_or(repository)
    )
}

fn valid_homebrew_token(token: &str) -> bool {
    !token.is_empty()
        && !Path::new(token).is_absolute()
        && !Path::new(token).components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
        && token
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "@+._/-".contains(character))
}

fn find_file_recursive(root: &Path, filename: &str) -> Option<PathBuf> {
    let mut entries: Vec<_> = fs::read_dir(root).ok()?.filter_map(Result::ok).collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        if path.is_file() && entry.file_name() == filename {
            return Some(path);
        }
        if path.is_dir() {
            if let Some(found) = find_file_recursive(&path, filename) {
                return Some(found);
            }
        }
    }
    None
}

fn path_exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

fn copy_generated_path(source_root: &Path, destination_root: &Path, relative: &Path) -> Result<()> {
    let source = source_root.join(relative);
    if !path_exists(&source) || should_skip(&source) {
        return Ok(());
    }
    let destination = destination_root.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_node(&source, &destination)
}

fn copy_store_path(source: &Path, destination_root: &Path, relative: &Path) -> Result<()> {
    if !path_exists(source) || should_skip(source) {
        return Ok(());
    }
    let destination = destination_root.join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    copy_node(source, &destination)
}

fn copy_node(source: &Path, destination: &Path) -> Result<()> {
    let symlink_metadata = fs::symlink_metadata(source)?;
    if symlink_metadata.file_type().is_symlink() && fs::metadata(source).is_err() {
        let target = fs::read_link(source)?;
        fs::write(
            destination,
            normalize_store_paths(&format!("broken symlink -> {}\n", target.display())),
        )?;
        return Ok(());
    }
    if fs::metadata(source)?.is_dir() {
        fs::create_dir_all(destination)?;
        let mut entries: Vec<_> = fs::read_dir(source)?.collect::<io::Result<_>>()?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let child = entry.path();
            if !should_skip(&child) {
                copy_node(&child, &destination.join(entry.file_name()))?;
            }
        }
        return Ok(());
    }

    let bytes = fs::read(source)?;
    if !bytes.is_empty() && !bytes.contains(&0) {
        if let Ok(text) = std::str::from_utf8(&bytes) {
            fs::write(destination, normalize_store_paths(text))?;
            let mut permissions = fs::metadata(destination)?.permissions();
            permissions.set_mode(permissions.mode() | 0o200);
            fs::set_permissions(destination, permissions)?;
            return Ok(());
        }
    }
    fs::copy(source, destination)?;
    Ok(())
}

fn should_skip(path: &Path) -> bool {
    let path = path.to_string_lossy();
    [
        "/etc/profiles",
        "/share/man",
        "/etc/ssl/trust-source",
        "/etc/terminfo",
        "/etc/zoneinfo",
    ]
    .iter()
    .any(|pattern| at_or_below(&path, pattern))
        || [
            "/etc/pki/tls/certs/ca-bundle.crt",
            "/etc/ssl/certs/ca-bundle.crt",
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/ssh/moduli",
            "/etc/issue",
            "/etc/issue.net",
            "/etc/os-release",
            "/etc/lsb-release",
        ]
        .iter()
        .any(|pattern| path.ends_with(pattern))
}

fn at_or_below(path: &str, pattern: &str) -> bool {
    path.ends_with(pattern) || path.contains(&format!("{pattern}/"))
}

fn filter_dix_output(output: &str) -> String {
    let mut filtered = String::new();
    let mut seen = false;
    for line in output.lines() {
        let plain = strip_ansi(line);
        if plain.starts_with("<<< ") || plain.starts_with(">>> ") {
            continue;
        }
        if let Some(package) = dix_package_name(&plain) {
            if package == "source" || package.starts_with("nixos-system-") {
                continue;
            }
        }
        if !seen && plain.is_empty() {
            continue;
        }
        seen = true;
        filtered.push_str(line);
        filtered.push('\n');
    }
    filtered
}

fn dix_package_name(line: &str) -> Option<&str> {
    let rest = line.strip_prefix('[')?.split_once(']')?.1.trim_start();
    rest.split_whitespace().next()
}

fn strip_ansi(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == 0x1b && bytes.get(index + 1) == Some(&b'[') {
            let mut end = index + 2;
            while end < bytes.len() && (bytes[end].is_ascii_digit() || bytes[end] == b';') {
                end += 1;
            }
            if bytes.get(end) == Some(&b'm') {
                index = end + 1;
                continue;
            }
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn filter_binary_diff_output(output: &str) -> String {
    let mut filtered = String::new();
    for line in output.lines() {
        if line.starts_with("Binary files ") && line.contains(" and ") && line.ends_with(" differ")
        {
            continue;
        }
        filtered.push_str(line);
        filtered.push('\n');
    }
    filtered
}

fn normalize_store_paths(value: &str) -> String {
    const PREFIX: &str = "/nix/store/";
    let mut output = String::with_capacity(value.len());
    let mut remaining = value;
    while let Some(position) = remaining.find(PREFIX) {
        output.push_str(&remaining[..position]);
        let candidate = &remaining[position..];
        if let Some(end) = store_path_end(candidate) {
            output.push_str("/nix/store/<path>");
            remaining = &candidate[end..];
        } else {
            output.push_str(PREFIX);
            remaining = &candidate[PREFIX.len()..];
        }
    }
    output.push_str(remaining);
    output
}

fn store_path_end(candidate: &str) -> Option<usize> {
    const PREFIX: &str = "/nix/store/";
    let bytes = candidate.as_bytes();
    let hash_start = PREFIX.len();
    let hash_end = hash_start + 32;
    if bytes.len() <= hash_end
        || !bytes[hash_start..hash_end]
            .iter()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    {
        return None;
    }
    let name_start = if bytes.get(hash_end) == Some(&b'-') {
        hash_end + 1
    } else if bytes.get(hash_end..hash_end + 2) == Some(b"\\-") {
        hash_end + 2
    } else {
        return None;
    };
    let end = bytes[name_start..]
        .iter()
        .position(|byte| {
            matches!(
                byte,
                b'/' | b' ' | b'\t' | b'\r' | b'\n' | b'\'' | b'"' | b'<' | b'>'
            )
        })
        .map_or(bytes.len(), |offset| name_start + offset);
    (end > name_start).then_some(end)
}

#[cfg(test)]
mod tests;
