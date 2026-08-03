use std::fs;
use std::path::Path;

pub const DEFAULT_NIX_CONF: &str = "/etc/nix/nix.conf";
pub const DEFAULT_NIX_MACHINES: &str = "/etc/nix/machines";

pub fn read_builders(nix_conf: &Path, nix_machines: &Path) -> Option<String> {
    fs::read_to_string(nix_conf)
        .ok()
        .and_then(|content| builders_from_nix_conf(&content))
        .or_else(|| {
            fs::read_to_string(nix_machines)
                .ok()
                .and_then(|content| builders_from_machines(&content))
        })
}

pub fn local_builders(builders: &str) -> String {
    builders
        .split(';')
        .filter(|builder| *builder == "localhost")
        .collect::<Vec<_>>()
        .join(";")
}

fn builders_from_nix_conf(content: &str) -> Option<String> {
    content
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            (key.trim() == "builders").then(|| value.trim().to_owned())
        })
        .next_back()
        .filter(|builders| !builders.is_empty())
}

fn builders_from_machines(content: &str) -> Option<String> {
    let builders = content
        .lines()
        .filter(|line| {
            line.split_whitespace()
                .next()
                .is_some_and(|first| !first.starts_with('#'))
        })
        .collect::<Vec<_>>()
        .join(";");
    (!builders.is_empty()).then_some(builders)
}

#[cfg(test)]
mod tests {
    use super::{builders_from_machines, builders_from_nix_conf, local_builders};

    #[test]
    fn nix_conf_accepts_whitespace_and_uses_last_value() {
        let content = "builders = old\ntrusted-users = root\n  builders = new1;new2\n";

        assert_eq!(
            builders_from_nix_conf(content).as_deref(),
            Some("new1;new2")
        );
    }

    #[test]
    fn empty_nix_conf_value_allows_machines_fallback() {
        assert_eq!(builders_from_nix_conf("builders =\n"), None);
    }

    #[test]
    fn machines_ignores_comments_and_empty_lines() {
        let content = "# comment\nbuilder1 x86_64-linux /etc/nix/id 4 1\n\n\
                       builder2 aarch64-linux /etc/nix/id 2 1\n";

        assert_eq!(
            builders_from_machines(content).as_deref(),
            Some(
                "builder1 x86_64-linux /etc/nix/id 4 1;\
                 builder2 aarch64-linux /etc/nix/id 2 1"
            )
        );
    }

    #[test]
    fn local_selection_keeps_only_exact_localhost_entries() {
        assert_eq!(
            local_builders("remote1;localhost;darwin-vm;localhost;remote2"),
            "localhost;localhost"
        );
    }
}
