#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sops-merge-template.sh --host HOST

Merges secrets/_templates/HOST.yaml into secrets/HOST.yaml.
Template keys are added only if missing; existing values win.
EOF
}

main() {
  host=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        host="$2"
        shift 2
        ;;
      *)
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$host" ]]; then
    usage
    exit 1
  fi

  template="secrets/_templates/${host}.yaml"
  secret="secrets/${host}.yaml"

  if [[ ! -f "$template" ]]; then
    echo "Template not found: $template"
    exit 1
  fi

  if [[ ! -f "$secret" ]]; then
    echo "Secret not found: $secret"
    exit 1
  fi

  tmp="$(mktemp)"
  merged="$(mktemp)"

  trap 'rm -f "$tmp" "$merged"' EXIT

  sops --decrypt "$secret" > "$tmp"
  yq -s '.[0] * .[1]' "$template" "$tmp" > "$merged"
  sops --encrypt --input-type yaml --output-type yaml "$merged" > "$secret"

  echo "Merged template into $secret."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
