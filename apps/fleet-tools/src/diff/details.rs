use std::collections::BTreeSet;
use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

use anyhow::{bail, Result};

use super::{
    copy_generated_path, copy_store_path, path_exists, DiffBackend, GeneratedPath,
    HomebrewManifest, RecursiveDiff, Revision, TargetKind,
};

#[allow(clippy::too_many_arguments)]
pub(super) fn run_detail_diff(
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

pub(super) fn materialize_homebrew_revision(
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

pub(super) fn find_recipe(
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

pub(super) fn canonical_tap(tap: &str) -> String {
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
