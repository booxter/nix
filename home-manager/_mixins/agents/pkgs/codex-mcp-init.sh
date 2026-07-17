#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: codex-mcp-init <mcp-name>
       codex-mcp-init --all

Authenticate one MCP server or every enabled HTTP MCP server in list order.
USAGE
}

list_mcp_names() {
  codex mcp list --json | jq -r '
    .[]
    | select(.enabled and .transport.type == "streamable_http")
    | .name
  '
}

print_mcp_options() {
  local mcp_name
  local mcp_names_output

  printf '\nEnabled HTTP MCPs:\n'
  if ! mcp_names_output="$(list_mcp_names)"; then
    printf '  (unable to read Codex MCP configuration)\n'
    return
  fi

  if [ -z "$mcp_names_output" ]; then
    printf '  (none)\n'
    return
  fi

  while IFS= read -r mcp_name; do
    printf '  %s\n' "$mcp_name"
  done <<<"$mcp_names_output"
}

if [ "$#" -eq 0 ]; then
  usage >&2
  print_mcp_options >&2
  exit 2
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  --all)
    mcp_names_output="$(list_mcp_names)"
    if [ -z "$mcp_names_output" ]; then
      echo "No enabled HTTP MCP servers found." >&2
      exit 1
    fi
    mapfile -t mcp_names <<<"$mcp_names_output"
    ;;
  -h | --help)
    usage
    print_mcp_options
    exit 0
    ;;
  -*)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  *)
    mcp_names=("$1")
    ;;
esac

for mcp_name in "${mcp_names[@]}"; do
  printf 'Initializing MCP %s...\n' "$mcp_name"
  codex mcp login "$mcp_name"
done
