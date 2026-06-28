#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  apps/sops/sops-update.sh --force [HOST]
  apps/sops/sops-update.sh [HOST]
  apps/sops/sops-update.sh --help

Update secrets/HOST.yaml from template defaults in secrets/_template.yaml and,
if present, secrets/_templates/HOST.yaml.

If HOST is omitted, the current short hostname is used.
Template keys are added only if missing; existing values win.
With --force, the secret is re-encrypted even if decrypted content is unchanged.
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

main() {
  host=""
  force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
      *)
        if [[ -z "$host" ]]; then
          host="$1"
          shift
        else
          usage
          exit 1
        fi
        ;;
    esac
  done

  if [[ -z "$host" ]]; then
    host="$(hostname -s)"
  fi

  local repo_root
  repo_root="$(resolve_repo_root)"
  # shellcheck disable=SC1091
  source "${repo_root}/apps/_helpers/host-aliases.sh"
  host="$(canonical_secret_host "$repo_root" "$host")"
  template="${repo_root}/secrets/_template.yaml"
  host_template="${repo_root}/secrets/_templates/${host}.yaml"
  secret="${repo_root}/secrets/${host}.yaml"

  if [[ ! -f "$template" ]]; then
    echo "Template not found: $template"
    exit 1
  fi

  if [[ ! -f "$secret" ]]; then
    echo "Secret not found: $secret"
    exit 1
  fi

  tmp="$(mktemp)"
  base="$(mktemp)"
  merged="$(mktemp)"
  sorted="$(mktemp)"
  current_sorted="$(mktemp)"
  encrypted="$(mktemp)"
  missing_updates="$(mktemp)"
  update_value="$(mktemp)"

  trap 'rm -f "$tmp" "$base" "$merged" "$sorted" "$current_sorted" "$encrypted" "$missing_updates" "$update_value"' EXIT

  sops --decrypt "$secret" > "$tmp"
  cp "$template" "$base"
  if [[ -f "$host_template" ]]; then
    yq ea 'select(fileIndex == 0) * select(fileIndex == 1)' "$base" "$host_template" > "$merged"
    mv "$merged" "$base"
  fi
  yq ea 'select(fileIndex == 0) * select(fileIndex == 1)' "$base" "$tmp" > "$merged"

  # Normalize to JSON and sort keys recursively for deterministic comparisons.
  yq -o=json '.' "$merged" | jq -S 'del(.sops)' > "$sorted"
  yq -o=json '.' "$tmp" | jq -S 'del(.sops)' > "$current_sorted"

  if [[ "$force" != "1" ]] && cmp -s "$current_sorted" "$sorted"; then
    if [[ "${SOPS_UPDATE_QUIET:-0}" != "1" ]]; then
      echo "Secret already up to date: $secret"
    fi
    return 0
  fi

  if [[ "$force" == "1" ]]; then
    sops --encrypt --filename-override "$secret" --input-type json --output-type yaml "$sorted" > "$encrypted"
    mv "$encrypted" "$secret"
  else
    jq -c -n \
      --slurpfile current "$current_sorted" \
      --slurpfile desired "$sorted" \
      '
        def path_exists($path):
          reduce $path[] as $key
            ({ exists: true, value: . };
              if (.exists | not) then
                .
              elif ((.value | type) == "object" and ($key | type) == "string") then
                if (.value | has($key)) then
                  { exists: true, value: .value[$key] }
                else
                  { exists: false, value: null }
                end
              elif ((.value | type) == "array" and ($key | type) == "number") then
                if ($key >= 0 and $key < (.value | length)) then
                  { exists: true, value: .value[$key] }
                else
                  { exists: false, value: null }
                end
              else
                { exists: false, value: null }
              end)
          | .exists;

        def sops_index:
          map(
            if type == "number" then
              "[" + tostring + "]"
            else
              "[" + @json + "]"
            end
          )
          | join("");

        $current[0] as $current_doc
        | $desired[0] as $desired_doc
        | $desired_doc
        | paths(type != "object" and type != "array") as $path
        | select(($current_doc | path_exists($path)) | not)
        | {
            path: ($path | sops_index),
            value: ($desired_doc | getpath($path))
          }
      ' > "$missing_updates"

    if [[ ! -s "$missing_updates" ]]; then
      sops --encrypt --filename-override "$secret" --input-type json --output-type yaml "$sorted" > "$encrypted"
      mv "$encrypted" "$secret"
    else
      while IFS= read -r update; do
        jq -c '.value' <<< "$update" > "$update_value"
        sops set --idempotent --value-stdin "$secret" "$(jq -r '.path' <<< "$update")" < "$update_value"
      done < "$missing_updates"
    fi
  fi

  if [[ "$force" == "1" ]] && cmp -s "$current_sorted" "$sorted"; then
    echo "Re-encrypted secret: $secret"
  else
    echo "Updated secret from templates: $secret"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
