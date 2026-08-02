#!/usr/bin/env bash
set -euo pipefail

package_file="pkgs/debugserver/default.nix"
latest_tag="$({
    curl --fail --location --silent --show-error \
        https://api.github.com/repos/vadimcn/codelldb/releases/latest
} | jq -er '.tag_name')"
version="${latest_tag#v}"

if [[ "$latest_tag" == "$version" ]]; then
    echo "Latest CodeLLDB release tag does not start with v: $latest_tag" >&2
    exit 1
fi

prefetch_hash() {
    local arch="$1"
    local url="https://github.com/vadimcn/codelldb/releases/download/${latest_tag}/codelldb-darwin-${arch}.vsix"

    nix store prefetch-file --json "$url" | jq -er '.hash'
}

arm64_hash="$(prefetch_hash arm64)"
x64_hash="$(prefetch_hash x64)"

sed -i \
    -e "s|version = \"[^\"]*\";|version = \"${version}\";|" \
    -e "/aarch64-darwin = {/,/};/ s|hash = \"[^\"]*\";|hash = \"${arm64_hash}\";|" \
    -e "/x86_64-darwin = {/,/};/ s|hash = \"[^\"]*\";|hash = \"${x64_hash}\";|" \
    "$package_file"
