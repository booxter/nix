#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  get-ff-cookie [DOMAIN]
  get-ff-cookie [--domain DOMAIN] [--profile PROFILE] [--container CONTAINER]
  get-ff-cookie [--domain DOMAIN] [--profile PROFILE] [URL ...]
  get-ff-cookie --help

Export Firefox cookies in Netscape cookies.txt format to stdout.

Defaults:
  DOMAIN  instagram.com
  Browser firefox

Examples:
  get-ff-cookie
  get-ff-cookie instagram.com
  get-ff-cookie --profile default-release instagram.com
  get-ff-cookie instagram.com | nix run .#sops-set -- --domain main beast lolek/galleryDlCookies

The cookie file is written only to a temporary file and then printed to stdout.
Progress and diagnostics go to stderr so stdout can be safely piped.
EOF
}

domain="instagram.com"
profile=""
container=""
declare -a urls=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --domain)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "--domain requires a non-empty value." >&2
        exit 1
      fi
      domain="$2"
      shift 2
      ;;
    --profile)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "--profile requires a non-empty value." >&2
        exit 1
      fi
      profile="$2"
      shift 2
      ;;
    --container)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "--container requires a non-empty value." >&2
        exit 1
      fi
      container="$2"
      shift 2
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        urls+=("$1")
        shift
      done
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *://*)
      urls+=("$1")
      shift
      ;;
    *)
      domain="$1"
      shift
      ;;
  esac
done

domain="${domain#http://}"
domain="${domain#https://}"
domain="${domain%%/*}"
domain="${domain%%:*}"

if [[ -z "$domain" ]]; then
  echo "Cookie domain must not be empty." >&2
  exit 1
fi

browser_spec="firefox/${domain}"
if [[ -n "$profile" ]]; then
  browser_spec+=":${profile}"
fi
if [[ -n "$container" ]]; then
  browser_spec+="::${container}"
fi

cookie_file="$(mktemp)"
trap 'rm -f "${cookie_file:-}"' EXIT

echo "Exporting Firefox cookies for ${domain}..." >&2
gallery-dl \
  --config-ignore \
  --quiet \
  --cookies-from-browser "$browser_spec" \
  --cookies-export "$cookie_file" \
  --simulate \
  "${urls[@]}" \
  >/dev/null

if ! grep -Eq '^[^#[:space:]]' "$cookie_file"; then
  echo "No cookies were exported for ${domain}; check that Firefox is logged in for that site." >&2
  exit 1
fi

cat "$cookie_file"
