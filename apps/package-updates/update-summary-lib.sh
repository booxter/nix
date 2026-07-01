# shellcheck shell=bash

github_repo_url_from_url() {
  local url="$1"
  local rest owner repo

  url="${url%%#*}"
  url="${url%%\?*}"
  case "$url" in
    https://github.com/*/*)
      rest="${url#https://github.com/}"
      owner="${rest%%/*}"
      rest="${rest#*/}"
      repo="${rest%%/*}"
      repo="${repo%.git}"
      if [[ -n "$owner" && -n "$repo" ]]; then
        printf 'https://github.com/%s/%s\n' "$owner" "$repo"
      fi
      ;;
  esac
}

github_ref_from_url() {
  local url="$1"
  local ref=""

  url="${url%%#*}"
  url="${url%%\?*}"
  case "$url" in
    */releases/tag/*)
      ref="${url#*/releases/tag/}"
      ;;
    */tree/*)
      ref="${url#*/tree/}"
      ;;
    */commit/*)
      ref="${url#*/commit/}"
      ;;
  esac

  ref="${ref%/}"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "$ref"
  fi
}

normalize_git_ref() {
  local ref="$1"

  ref="${ref#refs/tags/}"
  ref="${ref#refs/heads/}"
  printf '%s\n' "$ref"
}

github_compare_url() {
  local repo_url="$1"
  local old_ref="$2"
  local new_ref="$3"

  old_ref="$(normalize_git_ref "$old_ref")"
  new_ref="$(normalize_git_ref "$new_ref")"

  if [[ -n "$repo_url" && -n "$old_ref" && -n "$new_ref" && "$old_ref" != "$new_ref" ]]; then
    printf '%s/compare/%s...%s\n' "$repo_url" "$old_ref" "$new_ref"
  fi
}

github_compare_url_from_sources() {
  local old_source_url="$1"
  local old_ref="$2"
  local new_source_url="$3"
  local new_ref="$4"
  local old_repo new_repo repo_url

  old_repo="$(github_repo_url_from_url "$old_source_url")"
  new_repo="$(github_repo_url_from_url "$new_source_url")"
  if [[ -n "$old_repo" && -n "$new_repo" && "$old_repo" != "$new_repo" ]]; then
    return
  fi

  repo_url="${new_repo:-$old_repo}"
  github_compare_url "$repo_url" "$old_ref" "$new_ref"
}

github_compare_url_from_changelogs() {
  local old_changelog="$1"
  local new_changelog="$2"
  local old_repo new_repo old_ref new_ref

  old_repo="$(github_repo_url_from_url "$old_changelog")"
  new_repo="$(github_repo_url_from_url "$new_changelog")"
  if [[ -z "$old_repo" || -z "$new_repo" || "$old_repo" != "$new_repo" ]]; then
    return
  fi

  old_ref="$(github_ref_from_url "$old_changelog")"
  new_ref="$(github_ref_from_url "$new_changelog")"
  github_compare_url "$new_repo" "$old_ref" "$new_ref"
}

markdown_link_or_not_set() {
  local label="$1"
  local url="$2"

  if [[ -n "$url" ]]; then
    printf '[%s](%s)\n' "$label" "$url"
  else
    printf 'not set\n'
  fi
}
