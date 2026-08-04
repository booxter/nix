mod backend;
mod details;
mod output;
mod revision;
mod target;
mod tree;
mod workflow;

use backend::{DiffBackend, HomebrewManifest, NativeBackend, RecursiveDiff};
use details::run_detail_diff;
#[cfg(test)]
use details::{canonical_tap, find_recipe, materialize_homebrew_revision};
use output::{filter_binary_diff_output, filter_dix_output, normalize_store_paths};
use revision::{GitCheckout, Revision, RevisionSide};
pub use target::{DiffOptions, GeneratedPath, TargetKind, TargetRequest};
use tree::{copy_generated_path, copy_store_path, path_exists};
pub use workflow::execute;
#[cfg(test)]
use workflow::run_with_backend;

#[cfg(test)]
mod tests;
