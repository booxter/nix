#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  apps/package-updates/update-packages.sh [--summary-file PATH] [--targets-file PATH] [--target ATTR]
  apps/package-updates/update-packages.sh --list-targets
  apps/package-updates/update-packages.sh --help

Run package passthru.updateScript when available, otherwise run nix-update for
selected flake package attrs, and write a Markdown summary with changelog links.
Package builds are intentionally not run here; normal CI is responsible for
validating the resulting pull request.
EOF
}

resolve_repo_root() {
  if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "$PWD" rev-parse --show-toplevel
    return
  fi
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  cd -- "${script_dir}/../.." && pwd
}

nix_eval_raw() {
  local expr="$1"
  nix eval --option eval-cache false --raw "$expr" 2>/dev/null || true
}

nix_eval_json() {
  local expr="$1"
  nix eval --option eval-cache false --json "$expr" 2>/dev/null || true
}

target_rows() {
  local targets_file="$1"
  local target_filter="$2"

  jq -c --arg target "$target_filter" '
    .targets[]
    | select($target == "" or .attr == $target)
  ' "$targets_file"
}

target_count() {
  local targets_file="$1"
  local target_filter="$2"

  target_rows "$targets_file" "$target_filter" | jq -s 'length'
}

list_targets() {
  local targets_file="$1"

  jq -r '.targets[] | "\(.attr)\t\(.system // "x86_64-linux")"' "$targets_file"
}

write_summary_header() {
  local summary_file="$1"

  cat > "$summary_file" <<'EOF'
Automated package source update.

Package builds were not run by the updater. Normal CI is expected to validate
whether the updated package still builds or needs follow-up fixes.

| Package | Version | Changelog |
| --- | --- | --- |
EOF
}

append_summary_row() {
  local summary_file="$1"
  local attr="$2"
  local old_version="$3"
  local new_version="$4"
  local changelog="$5"

  local version_text
  if [[ -n "$old_version" && -n "$new_version" && "$old_version" != "$new_version" ]]; then
    version_text="${old_version} -> ${new_version}"
  elif [[ -n "$new_version" ]]; then
    version_text="${new_version}"
  else
    version_text="unknown"
  fi

  local changelog_text
  if [[ -n "$changelog" ]]; then
    changelog_text="[link](${changelog})"
  else
    changelog_text="not set"
  fi

  # shellcheck disable=SC2016 # Literal Markdown backticks in the printf format.
  printf '| `%s` | `%s` | %s |\n' "$attr" "$version_text" "$changelog_text" >> "$summary_file"
}

run_package_update_script() {
  local attr="$1"
  local system="$2"
  local update_script_json="$3"
  local update_script_installable=".#packages.${system}.${attr}.passthru.updateScript"

  local -a update_script_args update_script_outputs
  mapfile -t update_script_outputs < <(nix build --no-link --print-out-paths "$update_script_installable" 2>/dev/null || true)
  if [[ "${#update_script_outputs[@]}" -gt 0 ]]; then
    local update_script_out main_program
    update_script_out="${update_script_outputs[0]}"
    main_program="$(nix_eval_raw "${update_script_installable}.meta.mainProgram")"

    if [[ -n "$main_program" && -x "${update_script_out}/bin/${main_program}" ]]; then
      update_script_args=("${update_script_out}/bin/${main_program}")
    elif [[ -x "$update_script_out" ]]; then
      update_script_args=("$update_script_out")
    else
      echo "Could not find executable for passthru.updateScript of ${attr}" >&2
      return 2
    fi

    echo "running passthru.updateScript"
    UPDATE_NIX_ATTR_PATH="$attr" UPDATE_NIX_SYSTEM="$system" "${update_script_args[@]}"
    return
  fi

  if [[ -z "$update_script_json" || "$update_script_json" == "null" ]]; then
    return 1
  fi

  local update_script_type
  update_script_type="$(jq -r 'type' <<< "$update_script_json")"

  case "$update_script_type" in
    array)
      if [[ "$(jq 'length' <<< "$update_script_json")" -eq 0 ]]; then
        return 1
      fi
      mapfile -t update_script_args < <(jq -r '.[]' <<< "$update_script_json")
      ;;
    string)
      mapfile -t update_script_args < <(jq -r '.' <<< "$update_script_json")
      ;;
    object)
      echo "Unsupported passthru.updateScript object for ${attr}" >&2
      return 2
      ;;
    *)
      echo "Unsupported passthru.updateScript type for ${attr}: ${update_script_type}" >&2
      return 2
      ;;
  esac

  echo "running passthru.updateScript"
  UPDATE_NIX_ATTR_PATH="$attr" UPDATE_NIX_SYSTEM="$system" "${update_script_args[@]}"
}

main() {
  local repo_root
  repo_root="$(resolve_repo_root)"

  local targets_file="${PACKAGE_UPDATE_TARGETS_FILE:-${repo_root}/apps/package-updates/targets.json}"
  local summary_file="${PACKAGE_UPDATE_SUMMARY_FILE:-${repo_root}/package-update-summary.md}"
  local target_filter=""
  local list_only=0

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --summary-file)
        summary_file="$2"
        shift 2
        ;;
      --targets-file)
        targets_file="$2"
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

  if [[ ! -f "$targets_file" ]]; then
    echo "Package update targets file not found: $targets_file" >&2
    exit 1
  fi

  if [[ "$list_only" -eq 1 ]]; then
    list_targets "$targets_file"
    exit 0
  fi

  local count
  count="$(target_count "$targets_file" "$target_filter")"
  if [[ "$count" -eq 0 ]]; then
    echo "No package update targets matched." >&2
    exit 1
  fi

  mkdir -p "$(dirname -- "$summary_file")"
  write_summary_header "$summary_file"

  cd "$repo_root"

  local target
  while IFS= read -r target; do
    local attr system nix_update_system old_version old_changelog new_version new_changelog update_script_json update_script_status
    attr="$(jq -r '.attr' <<< "$target")"
    system="$(jq -r '.system // "x86_64-linux"' <<< "$target")"
    nix_update_system="$(jq -r '.nixUpdateSystem // .system // "x86_64-linux"' <<< "$target")"

    old_version="$(nix_eval_raw ".#packages.${system}.${attr}.version")"
    old_changelog="$(nix_eval_raw ".#packages.${system}.${attr}.meta.changelog")"

    echo "::group::Updating ${attr}"
    echo "system: ${system}"
    if [[ "$nix_update_system" != "$system" ]]; then
      echo "nix-update system: ${nix_update_system}"
    fi
    if [[ -n "$old_version" ]]; then
      echo "old version: ${old_version}"
    fi
    if [[ -n "$old_changelog" ]]; then
      echo "old changelog: ${old_changelog}"
    fi

    local -a nix_update_args
    mapfile -t nix_update_args < <(jq -r '.nixUpdateArgs[]?' <<< "$target")
    update_script_json="$(nix_eval_json ".#packages.${nix_update_system}.${attr}.passthru.updateScript")"
    if run_package_update_script "$attr" "$nix_update_system" "$update_script_json"; then
      :
    else
      update_script_status="$?"
      if [[ "$update_script_status" -eq 1 ]]; then
        nix-update --flake --system "$nix_update_system" "${nix_update_args[@]}" "$attr"
      else
        exit "$update_script_status"
      fi
    fi
    echo "::endgroup::"

    new_version="$(nix_eval_raw ".#packages.${system}.${attr}.version")"
    new_changelog="$(nix_eval_raw ".#packages.${system}.${attr}.meta.changelog")"
    append_summary_row "$summary_file" "$attr" "$old_version" "$new_version" "$new_changelog"
  done < <(target_rows "$targets_file" "$target_filter")

  cat >> "$summary_file" <<'EOF'

Generated by GitHub Actions.
EOF

  echo "Wrote package update summary: $summary_file"
}

main "$@"
