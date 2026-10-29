use std::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Classification {
    Unchanged,
    Minor,
    Major,
    Error,
}

impl fmt::Display for Classification {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unchanged => "unchanged",
            Self::Minor => "minor",
            Self::Major => "major",
            Self::Error => "error",
        })
    }
}

pub fn classify(output: &str, exit_code: i32) -> Classification {
    if exit_code != 0 {
        return Classification::Error;
    }
    if is_unchanged(output) {
        return Classification::Unchanged;
    }
    if is_size_only(output) {
        return Classification::Minor;
    }
    Classification::Major
}

fn is_unchanged(output: &str) -> bool {
    if output.is_empty() {
        return true;
    }

    let mut lines = output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty());
    let mut first = lines.next();
    if let Some(paths) = first.and_then(|line| line.strip_prefix("PATHS: ")) {
        let Some((old, new)) = paths
            .strip_suffix(" (+0, -0)")
            .and_then(|counts| counts.split_once(" -> "))
        else {
            return false;
        };
        if !is_digits(old) || !is_digits(new) || old != new {
            return false;
        }
        first = lines.next();
    }

    let Some((old, new)) = first
        .and_then(|line| line.strip_prefix("SIZE: "))
        .and_then(|size| size.split_once(" -> "))
    else {
        return false;
    };
    if old != new || lines.next() != Some("DIFF: 0 bytes") {
        return false;
    }

    match lines.next() {
        None => true,
        Some("No generated config differences.") => lines.next().is_none(),
        Some(_) => false,
    }
}

fn is_size_only(output: &str) -> bool {
    let has_size = output.lines().any(|line| {
        line.strip_prefix("SIZE: ")
            .and_then(|size| size.split_once(" -> "))
            .is_some_and(|(old, new)| !old.is_empty() && !new.is_empty())
    });
    let has_delta = output.lines().any(|line| {
        line.strip_prefix("DIFF: ")
            .is_some_and(|delta| !delta.is_empty())
    });

    has_size
        && has_delta
        && !output.lines().any(is_package_change)
        && !has_generated_config_diff(output)
}

fn is_package_change(line: &str) -> bool {
    let Some((status, row)) = line.strip_prefix('[').and_then(|line| line.split_once(']')) else {
        return false;
    };
    if status.is_empty() || !row.starts_with(char::is_whitespace) || row.trim().is_empty() {
        return false;
    }

    let fields: Vec<_> = row.split_whitespace().collect();
    // A size-only row has a package name, signed decimal, and size unit.
    // Versions, additions, and removals remain major changes.
    !matches!(fields.as_slice(), [_, size, unit] if is_decimal(size) && is_size_unit(unit))
}

fn is_digits(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn is_decimal(value: &str) -> bool {
    let unsigned = value.strip_prefix(['+', '-']).unwrap_or(value);
    match unsigned.split_once('.') {
        Some((whole, fraction)) => is_digits(whole) && is_digits(fraction),
        None => is_digits(unsigned),
    }
}

fn is_size_unit(value: &str) -> bool {
    matches!(
        value,
        "byte" | "bytes" | "KiB" | "MiB" | "GiB" | "TiB" | "PiB" | "EiB" | "ZiB" | "YiB"
    )
}

fn has_generated_config_diff(output: &str) -> bool {
    if output.contains("No generated config differences.") {
        return false;
    }
    output.lines().any(|line| {
        ["diff -ruN ", "Only in ", "--- ", "+++ ", "@@ "]
            .iter()
            .any(|prefix| line.starts_with(prefix))
            || ((line.starts_with("Files ") || line.starts_with("Binary files "))
                && line.contains(" differ"))
    })
}

#[cfg(test)]
mod tests {
    use super::{classify, Classification};

    #[test]
    fn classifies_existing_diff_reports() {
        let cases = [
            ("", Classification::Unchanged),
            (
                "PATHS: 2 -> 2 (+0, -0)\nSIZE: 1 MiB -> 1 MiB\nDIFF: 0 bytes\nNo generated config differences.\n",
                Classification::Unchanged,
            ),
            (
                "SIZE: 1 MiB -> 1 MiB\nDIFF: 0 bytes\n",
                Classification::Unchanged,
            ),
            (
                "[C.] example +2 MiB\nPATHS: 2 -> 2 (+1, -1)\nSIZE: 1 MiB -> 3 MiB\nDIFF: +2 MiB\n",
                Classification::Minor,
            ),
            (
                "PATHS: 2 -> 2 (+1, -1)\nSIZE: 1 MiB -> 1 MiB\nDIFF: 0 bytes\n",
                Classification::Minor,
            ),
            (
                "[U.] example 1.0 -> 2.0\nSIZE: 1 MiB -> 1 MiB\nDIFF: 0 bytes\n",
                Classification::Major,
            ),
            (
                "[A.] example 1.0\nSIZE: 1 MiB -> 2 MiB\nDIFF: +1 MiB\n",
                Classification::Major,
            ),
            (
                "[R.] example 1.0\nSIZE: 2 MiB -> 1 MiB\nDIFF: -1 MiB\n",
                Classification::Major,
            ),
            (
                "SIZE: 1 MiB -> 1 MiB\nDIFF: 0 bytes\n--- old/etc/config\n+++ new/etc/config\n@@ -1 +1 @@\n-before\n+after\n",
                Classification::Major,
            ),
        ];
        for (output, expected) in cases {
            assert_eq!(classify(output, 0), expected, "report:\n{output}");
        }
    }

    #[test]
    fn failed_comparisons_are_errors_even_with_empty_or_partial_output() {
        for output in ["", "SIZE: 1 MiB -> 1 MiB\nDIFF: 0 bytes\n"] {
            assert_eq!(classify(output, 1), Classification::Error);
        }
    }
}
