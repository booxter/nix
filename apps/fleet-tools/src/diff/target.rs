use std::fmt;
use std::path::{Component, Path, PathBuf};
use std::str::FromStr;

use anyhow::{bail, Result};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TargetKind {
    Nixos,
    Darwin,
}

impl TargetKind {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Nixos => "nixos",
            Self::Darwin => "darwin",
        }
    }

    pub(super) fn nh_subcommand(self) -> &'static str {
        match self {
            Self::Nixos => "os",
            Self::Darwin => "darwin",
        }
    }
}

impl fmt::Display for TargetKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TargetRequest {
    pub machine: String,
    pub explicit_kind: Option<TargetKind>,
}

impl FromStr for TargetRequest {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        let mut attribute = value;
        if let Some(stripped) = attribute.strip_prefix(".#") {
            attribute = stripped;
        } else if let Some(stripped) = attribute.strip_prefix('#') {
            attribute = stripped;
        } else if let Some(stripped) = attribute.strip_prefix('.') {
            attribute = stripped;
        }

        let (explicit_kind, machine) =
            if let Some(rest) = attribute.strip_prefix("nixosConfigurations.") {
                (Some(TargetKind::Nixos), first_attribute(rest))
            } else if let Some(rest) = attribute.strip_prefix("darwinConfigurations.") {
                (Some(TargetKind::Darwin), first_attribute(rest))
            } else {
                (None, attribute)
            };

        if machine.is_empty() {
            bail!("machine must not be empty");
        }

        Ok(Self {
            machine: machine.to_owned(),
            explicit_kind,
        })
    }
}

fn first_attribute(value: &str) -> &str {
    value.split('.').next().unwrap_or_default()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GeneratedPath(PathBuf);

impl GeneratedPath {
    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

impl fmt::Display for GeneratedPath {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.display().fmt(formatter)
    }
}

impl FromStr for GeneratedPath {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        let path = PathBuf::from(value);
        if value.is_empty()
            || path.is_absolute()
            || path.components().any(|component| {
                matches!(
                    component,
                    Component::ParentDir | Component::RootDir | Component::Prefix(_)
                )
            })
        {
            bail!("generated path must be a relative path without '..': {value}");
        }
        Ok(Self(path))
    }
}

#[derive(Clone, Debug)]
pub struct DiffOptions {
    pub details: bool,
    pub generated_paths: Vec<GeneratedPath>,
    pub target: TargetRequest,
    pub old_revision: String,
    pub new_revision: String,
}
