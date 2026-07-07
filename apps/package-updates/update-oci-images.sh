#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=apps/package-updates/update-summary-lib.sh
# shellcheck disable=SC1091
source "${UPDATE_SUMMARY_LIB:-${script_dir}/update-summary-lib.sh}"

usage() {
  cat <<'EOF'
Usage:
  apps/package-updates/update-oci-images.sh [--summary-file PATH] [--pins-file PATH] [--target NAME]
  apps/package-updates/update-oci-images.sh --list-targets
  apps/package-updates/update-oci-images.sh --help

Update pinned OCI image tags from oci/images.json and write a Markdown
summary. Tags are discovered from the upstream registry and filtered by each
target's tagRegex. The selected linux/amd64 image is prefetched into a Nix
fixed-output pin so same-tag digest rewrites are visible as file changes.
Targets with signature metadata are verified with vendored key material before
pins are updated.
EOF
}

resolve_repo_root() {
  if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
    return
  fi
  cd -- "${script_dir}/../.." && pwd
}

target_rows() {
  local pins_file="$1"
  local target_filter="$2"

  jq -c --arg target "$target_filter" '
    to_entries[]
    | select($target == "" or .key == $target)
    | {
        name: .key,
        image: .value.image,
        tag: .value.tag,
        digest: .value.digest,
        hash: .value.hash,
        tagRegex: (.value.tagRegex // "^[0-9]+\\.[0-9]+\\.[0-9]+$"),
        changelog: (.value.changelog // ""),
        signature: (.value.signature // {})
      }
  ' "$pins_file"
}

target_count() {
  local pins_file="$1"
  local target_filter="$2"

  target_rows "$pins_file" "$target_filter" | jq -s 'length'
}

list_targets() {
  local pins_file="$1"

  jq -r 'to_entries[] | "\(.key)\t\(.value.image):\(.value.tag)"' "$pins_file"
}

latest_tag_for_image() {
  local image="$1"
  local tag_regex="$2"
  local tags

  tags="$(
    skopeo list-tags "docker://${image}" \
      | jq -r '.Tags[]' \
      | grep -E "$tag_regex" || true
  )"

  if [[ -z "$tags" ]]; then
    echo "No tags for ${image} matched regex: ${tag_regex}" >&2
    return 1
  fi

  printf '%s\n' "$tags" | sort -V | tail -n 1
}

write_summary_header() {
  local summary_file="$1"

  cat > "$summary_file" <<'EOF'
Automated OCI image tag update.

OCI images were prefetched for linux/amd64 and pinned as Nix fixed-output
archives. Normal CI is expected to validate whether the updated image still
works with the managed service.

| Target | Image | Tag | Digest | Nix hash | Changelog | Diff | Signature |
| --- | --- | --- | --- | --- | --- | --- | --- |
EOF
}

change_text() {
  local old_value="$1"
  local new_value="$2"

  if [[ -n "$old_value" && "$old_value" != "null" && "$old_value" != "$new_value" ]]; then
    printf '%s -> %s\n' "$old_value" "$new_value"
  else
    printf '%s\n' "$new_value"
  fi
}

append_summary_row() {
  local summary_file="$1"
  local name="$2"
  local image="$3"
  local old_tag="$4"
  local new_tag="$5"
  local old_digest="$6"
  local new_digest="$7"
  local old_hash="$8"
  local new_hash="$9"
  local changelog="${10}"
  local diff_url="${11}"
  local signature="${12}"

  local tag_text
  tag_text="$(change_text "$old_tag" "$new_tag")"

  local digest_text hash_text changelog_text diff_text
  digest_text="$(change_text "$old_digest" "$new_digest")"
  hash_text="$(change_text "$old_hash" "$new_hash")"
  changelog_text="$(markdown_link_or_not_set "link" "$changelog")"
  diff_text="$(markdown_link_or_not_set "compare" "$diff_url")"

  # shellcheck disable=SC2016 # Literal Markdown backticks in the printf format.
  printf '| `%s` | `%s` | `%s` | `%s` | `%s` | %s | %s | `%s` |\n' \
    "$name" "$image" "$tag_text" "$digest_text" "$hash_text" "$changelog_text" "$diff_text" "$signature" >> "$summary_file"
}

replace_tag_template() {
  local template="$1"
  local tag="$2"

  printf '%s\n' "${template//\{tag\}/$tag}"
}

image_ref() {
  local image="$1"
  local tag="$2"
  local digest="$3"

  if [[ -n "$digest" && "$digest" != "null" ]]; then
    printf 'docker://%s@%s\n' "$image" "$digest"
  else
    printf 'docker://%s:%s\n' "$image" "$tag"
  fi
}

image_config_label() {
  local image="$1"
  local tag="$2"
  local digest="$3"
  local label="$4"

  if [[ -z "$tag" ]]; then
    return
  fi

  skopeo inspect --config "$(image_ref "$image" "$tag" "$digest")" 2>/dev/null \
    | jq -r --arg label "$label" '.config.Labels[$label] // .Labels[$label] // empty' \
    || true
}

image_diff_url() {
  local image="$1"
  local old_tag="$2"
  local new_tag="$3"
  local old_digest="$4"
  local new_digest="$5"
  local old_changelog="$6"
  local new_changelog="$7"
  local old_source old_revision new_source new_revision diff_url

  if [[ -z "$old_tag" || -z "$new_tag" || "$old_tag" == "$new_tag" ]]; then
    return
  fi

  old_source="$(image_config_label "$image" "$old_tag" "$old_digest" "org.opencontainers.image.source")"
  old_revision="$(image_config_label "$image" "$old_tag" "$old_digest" "org.opencontainers.image.revision")"
  new_source="$(image_config_label "$image" "$new_tag" "$new_digest" "org.opencontainers.image.source")"
  new_revision="$(image_config_label "$image" "$new_tag" "$new_digest" "org.opencontainers.image.revision")"

  diff_url="$(github_compare_url_from_sources "$old_source" "$old_revision" "$new_source" "$new_revision")"
  if [[ -z "$diff_url" ]]; then
    diff_url="$(github_compare_url_from_changelogs "$old_changelog" "$new_changelog")"
  fi
  printf '%s\n' "$diff_url"
}

prefetch_image() {
  local image="$1"
  local tag="$2"

  nix-prefetch-docker \
    --json \
    --quiet \
    --os linux \
    --arch amd64 \
    --image-name "$image" \
    --image-tag "$tag" \
    --final-image-name "$image" \
    --final-image-tag "$tag"
}

verify_image_signature() {
  local image="$1"
  local digest="$2"
  local signature="$3"
  local repo_root="$4"
  local signature_type key ref

  signature_type="$(jq -r '.type // empty' <<< "$signature")"
  if [[ -z "$signature_type" ]]; then
    printf 'not configured\n'
    return
  fi

  case "$signature_type" in
    cosign-key)
      key="$(jq -r '.key // empty' <<< "$signature")"
      if [[ -z "$key" ]]; then
        echo "Signature verification for ${image} is missing signature.key" >&2
        return 1
      fi
      if [[ "$key" == *"://"* ]]; then
        echo "Signature verification key for ${image} must be a vendored local path, got: ${key}" >&2
        return 1
      fi
      if [[ "$key" != /* ]]; then
        key="${repo_root}/${key}"
      fi
      if [[ ! -f "$key" ]]; then
        echo "Signature verification key for ${image} not found: ${key}" >&2
        return 1
      fi

      ref="${image}@${digest}"
      echo "verifying signature: cosign verify --key ${key} ${ref}" >&2
      if ! cosign verify --key "$key" "$ref" >/dev/null; then
        echo "Cosign verification failed for ${ref}" >&2
        return 1
      fi
      printf 'cosign verified\n'
      ;;
    *)
      echo "Unsupported signature verification type for ${image}: ${signature_type}" >&2
      return 1
      ;;
  esac
}

update_pin() {
  local pins_file="$1"
  local name="$2"
  local tag="$3"
  local digest="$4"
  local hash="$5"
  local pins_dir pins_base tmp

  pins_dir="$(dirname -- "$pins_file")"
  pins_base="$(basename -- "$pins_file")"
  tmp="$(mktemp "${pins_dir}/.${pins_base}.tmp.XXXXXX")"
  jq \
    --arg name "$name" \
    --arg tag "$tag" \
    --arg digest "$digest" \
    --arg hash "$hash" \
    '.[$name].tag = $tag | .[$name].digest = $digest | .[$name].hash = $hash' \
    "$pins_file" > "$tmp"
  mv "$tmp" "$pins_file"
}

main() {
  local repo_root
  repo_root="$(resolve_repo_root)"

  local pins_file="${OCI_IMAGE_PINS_FILE:-${repo_root}/oci/images.json}"
  local summary_file="${OCI_IMAGE_UPDATE_SUMMARY_FILE:-${repo_root}/oci-image-update-summary.md}"
  local target_filter=""
  local list_only=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --summary-file)
        summary_file="$2"
        shift 2
        ;;
      --pins-file)
        pins_file="$2"
        shift 2
        ;;
      --target)
        target_filter="$2"
        shift 2
        ;;
      --list-targets)
        list_only=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ ! -f "$pins_file" ]]; then
    echo "OCI image pins file not found: $pins_file" >&2
    exit 1
  fi

  if [[ "$list_only" -eq 1 ]]; then
    list_targets "$pins_file"
    exit 0
  fi

  local count
  count="$(target_count "$pins_file" "$target_filter")"
  if [[ "$count" -eq 0 ]]; then
    echo "No OCI image targets matched." >&2
    exit 1
  fi

  mkdir -p "$(dirname -- "$summary_file")"
  write_summary_header "$summary_file"

  local target
  while IFS= read -r target; do
    local name image old_tag old_digest old_hash tag_regex changelog_template signature prefetch new_tag new_digest new_hash signature_result old_changelog changelog diff_url
    name="$(jq -r '.name' <<< "$target")"
    image="$(jq -r '.image' <<< "$target")"
    old_tag="$(jq -r '.tag' <<< "$target")"
    old_digest="$(jq -r '.digest' <<< "$target")"
    old_hash="$(jq -r '.hash' <<< "$target")"
    tag_regex="$(jq -r '.tagRegex' <<< "$target")"
    changelog_template="$(jq -r '.changelog' <<< "$target")"
    signature="$(jq -c '.signature // {}' <<< "$target")"

    echo "::group::Updating OCI image ${name}"
    echo "image: ${image}"
    echo "old tag: ${old_tag}"
    echo "tag regex: ${tag_regex}"

    new_tag="$(latest_tag_for_image "$image" "$tag_regex")"
    echo "new tag: ${new_tag}"

    prefetch="$(prefetch_image "$image" "$new_tag")"
    new_digest="$(jq -r '.imageDigest' <<< "$prefetch")"
    new_hash="$(jq -r '.hash' <<< "$prefetch")"
    if [[ -z "$new_digest" || "$new_digest" == "null" || -z "$new_hash" || "$new_hash" == "null" ]]; then
      echo "Prefetch did not return digest and hash for ${image}:${new_tag}" >&2
      exit 1
    fi
    echo "new digest: ${new_digest}"
    echo "new hash: ${new_hash}"

    signature_result="$(verify_image_signature "$image" "$new_digest" "$signature" "$repo_root")"
    echo "signature: ${signature_result}"

    if [[ "$new_tag" != "$old_tag" || "$new_digest" != "$old_digest" || "$new_hash" != "$old_hash" ]]; then
      update_pin "$pins_file" "$name" "$new_tag" "$new_digest" "$new_hash"
    fi
    echo "::endgroup::"

    old_changelog="$(replace_tag_template "$changelog_template" "$old_tag")"
    changelog="$(replace_tag_template "$changelog_template" "$new_tag")"
    diff_url="$(image_diff_url "$image" "$old_tag" "$new_tag" "$old_digest" "$new_digest" "$old_changelog" "$changelog")"
    append_summary_row \
      "$summary_file" \
      "$name" \
      "$image" \
      "$old_tag" \
      "$new_tag" \
      "$old_digest" \
      "$new_digest" \
      "$old_hash" \
      "$new_hash" \
      "$changelog" \
      "$diff_url" \
      "$signature_result"
  done < <(target_rows "$pins_file" "$target_filter")

  cat >> "$summary_file" <<'EOF'

Generated by GitHub Actions.
EOF

  echo "Wrote OCI image update summary: $summary_file"
}

main "$@"
