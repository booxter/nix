# shellcheck shell=bash

set -euo pipefail

: "${source_relative_path:=Library/Application Support/Firefox}"
: "${destination_relative_path:=Library/Application Support/org.nixos.firefox}"

usage() {
  cat <<EOF
Usage: firefox-migrate-app-data [--dry-run] [--replace-existing]

Copy Firefox data from:
  ~/$source_relative_path

to the Nix Firefox app-data directory:
  ~/$destination_relative_path

The source is never modified or removed. --replace-existing preserves an
existing destination as a timestamped backup before replacing it.
EOF
}

replace=false
dry_run=false

while (( $# > 0 )); do
  case "$1" in
    --replace-existing)
      replace=true
      ;;
    --dry-run)
      dry_run=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

source_dir="$HOME/$source_relative_path"
destination_dir="$HOME/$destination_relative_path"

if [[ "$source_dir" == "$destination_dir" ]]; then
  printf 'Source and destination must be different directories.\n' >&2
  exit 1
fi

if [[ -L "$source_dir" || ! -d "$source_dir" ]]; then
  printf 'Firefox data directory not found: %s\n' "$source_dir" >&2
  exit 1
fi

if [[ ! -r "$source_dir/profiles.ini" ]]; then
  printf 'Cannot read %s/profiles.ini\n' "$source_dir" >&2
  printf 'macOS may be denying the invoking terminal access.\n' >&2
  exit 1
fi

if [[ -z "${FIREFOX_MIGRATE_SKIP_RUNNING_CHECK:-}" ]] \
  && /usr/bin/pgrep -f '/Firefox[.]app/Contents/MacOS/' >/dev/null; then
  printf 'Firefox is running; close it before migrating.\n' >&2
  exit 1
fi

if [[ -L "$destination_dir" ]]; then
  printf 'Refusing to replace symlink: %s\n' "$destination_dir" >&2
  exit 1
fi

if [[ -e "$destination_dir" && "$replace" != true ]]; then
  printf 'Destination already exists: %s\n' "$destination_dir" >&2
  printf 'Use --replace-existing to preserve it as a backup first.\n' >&2
  exit 1
fi

printf 'Source:      %s\n' "$source_dir"
printf 'Destination: %s\n' "$destination_dir"

if [[ "$dry_run" == true ]]; then
  exit 0
fi

destination_parent=${destination_dir%/*}
mkdir -p "$destination_parent"

temporary_dir=$(
  mktemp -d "$destination_parent/.firefox-app-data-migration.XXXXXX"
)

cleanup() {
  if [[ -n "${temporary_dir:-}" && -d "$temporary_dir" ]]; then
    rm -rf "$temporary_dir"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Do not carry extended attributes that may associate the copies with Mozilla's
# protected app-data directory. Preserve ordinary modes, timestamps, symlinks,
# and hard links, but create all destination files as the invoking user.
if ! cp \
  --recursive \
  --preserve=mode,timestamps,links \
  --no-preserve=ownership,xattr,context \
  "$source_dir/." \
  "$temporary_dir/"; then
  printf 'Failed to copy Firefox data; macOS may be denying access.\n' >&2
  exit 1
fi

# Never copy a live or stale profile lock.
find "$temporary_dir" -name .parentlock -delete

if [[ ! -r "$temporary_dir/profiles.ini" ]]; then
  printf 'Copied data failed validation: profiles.ini is missing.\n' >&2
  exit 1
fi

backup_dir=
if [[ -e "$destination_dir" ]]; then
  backup_dir="$destination_dir.pre-migration.$(date +%Y%m%d-%H%M%S).$$"
  mv "$destination_dir" "$backup_dir"
fi

if ! mv "$temporary_dir" "$destination_dir"; then
  if [[ -n "$backup_dir" ]]; then
    mv "$backup_dir" "$destination_dir"
  fi
  exit 1
fi
temporary_dir=

printf 'Migration completed.\n'
printf 'Original data remains at: %s\n' "$source_dir"

if [[ -n "$backup_dir" ]]; then
  printf 'Previous destination saved at: %s\n' "$backup_dir"
fi
