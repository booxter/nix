pub(super) fn filter_dix_output(output: &str) -> String {
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

pub(super) fn filter_binary_diff_output(output: &str) -> String {
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

pub(super) fn normalize_store_paths(value: &str) -> String {
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
