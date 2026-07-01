#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=apps/package-updates/update-summary-lib.sh
# shellcheck disable=SC1091
source "${script_dir}/update-summary-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  apps/package-updates/update-oci-images.sh [--summary-file PATH] [--pins-file PATH] [--target NAME]
  apps/package-updates/update-oci-images.sh --list-targets
  apps/package-updates/update-oci-images.sh --help

Update pinned OCI image tags from lib/oci-images.json and write a Markdown
summary. Tags are discovered from the upstream registry and filtered by each
target's tagRegex.
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
        tagRegex: (.value.tagRegex // "^[0-9]+\\.[0-9]+\\.[0-9]+$"),
        changelog: (.value.changelog // "")
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

Container builds were not run by the updater. Normal CI is expected to validate
whether the updated image tag still works with the managed service.

| Target | Image | Tag | Changelog | Diff |
| --- | --- | --- | --- | --- |
EOF
}

append_summary_row() {
  local summary_file="$1"
  local name="$2"
  local image="$3"
  local old_tag="$4"
  local new_tag="$5"
  local changelog="$6"
  local diff_url="$7"

  local tag_text
  if [[ "$old_tag" != "$new_tag" ]]; then
    tag_text="${old_tag} -> ${new_tag}"
  else
    tag_text="${new_tag}"
  fi

  local changelog_text diff_text
  changelog_text="$(markdown_link_or_not_set "link" "$changelog")"
  diff_text="$(markdown_link_or_not_set "compare" "$diff_url")"

  # shellcheck disable=SC2016 # Literal Markdown backticks in the printf format.
  printf '| `%s` | `%s` | `%s` | %s | %s |\n' "$name" "$image" "$tag_text" "$changelog_text" "$diff_text" >> "$summary_file"
}

replace_tag_template() {
  local template="$1"
  local tag="$2"

  printf '%s\n' "${template//\{tag\}/$tag}"
}

image_config_label() {
  local image="$1"
  local tag="$2"
  local label="$3"

  if [[ -z "$tag" ]]; then
    return
  fi

  skopeo inspect --config "docker://${image}:${tag}" 2>/dev/null \
    | jq -r --arg label "$label" '.config.Labels[$label] // .Labels[$label] // empty' \
    || true
}

image_diff_url() {
  local image="$1"
  local old_tag="$2"
  local new_tag="$3"
  local old_changelog="$4"
  local new_changelog="$5"
  local old_source old_revision new_source new_revision diff_url

  if [[ -z "$old_tag" || -z "$new_tag" || "$old_tag" == "$new_tag" ]]; then
    return
  fi

  old_source="$(image_config_label "$image" "$old_tag" "org.opencontainers.image.source")"
  old_revision="$(image_config_label "$image" "$old_tag" "org.opencontainers.image.revision")"
  new_source="$(image_config_label "$image" "$new_tag" "org.opencontainers.image.source")"
  new_revision="$(image_config_label "$image" "$new_tag" "org.opencontainers.image.revision")"

  diff_url="$(github_compare_url_from_sources "$old_source" "$old_revision" "$new_source" "$new_revision")"
  if [[ -z "$diff_url" ]]; then
    diff_url="$(github_compare_url_from_changelogs "$old_changelog" "$new_changelog")"
  fi
  printf '%s\n' "$diff_url"
}

update_pin() {
  local pins_file="$1"
  local name="$2"
  local tag="$3"
  local pins_dir pins_base tmp

  pins_dir="$(dirname -- "$pins_file")"
  pins_base="$(basename -- "$pins_file")"
  tmp="$(mktemp "${pins_dir}/.${pins_base}.tmp.XXXXXX")"
  jq --arg name "$name" --arg tag "$tag" '.[$name].tag = $tag' "$pins_file" > "$tmp"
  mv "$tmp" "$pins_file"
}

main() {
  local repo_root
  repo_root="$(resolve_repo_root)"

  local pins_file="${OCI_IMAGE_PINS_FILE:-${repo_root}/lib/oci-images.json}"
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
    local name image old_tag tag_regex changelog_template new_tag old_changelog changelog diff_url
    name="$(jq -r '.name' <<< "$target")"
    image="$(jq -r '.image' <<< "$target")"
    old_tag="$(jq -r '.tag' <<< "$target")"
    tag_regex="$(jq -r '.tagRegex' <<< "$target")"
    changelog_template="$(jq -r '.changelog' <<< "$target")"

    echo "::group::Updating OCI image ${name}"
    echo "image: ${image}"
    echo "old tag: ${old_tag}"
    echo "tag regex: ${tag_regex}"

    new_tag="$(latest_tag_for_image "$image" "$tag_regex")"
    echo "new tag: ${new_tag}"

    if [[ "$new_tag" != "$old_tag" ]]; then
      update_pin "$pins_file" "$name" "$new_tag"
    fi
    echo "::endgroup::"

    old_changelog="$(replace_tag_template "$changelog_template" "$old_tag")"
    changelog="$(replace_tag_template "$changelog_template" "$new_tag")"
    diff_url="$(image_diff_url "$image" "$old_tag" "$new_tag" "$old_changelog" "$changelog")"
    append_summary_row "$summary_file" "$name" "$image" "$old_tag" "$new_tag" "$changelog" "$diff_url"
  done < <(target_rows "$pins_file" "$target_filter")

  cat >> "$summary_file" <<'EOF'

Generated by GitHub Actions.
EOF

  echo "Wrote OCI image update summary: $summary_file"
}

main "$@"
