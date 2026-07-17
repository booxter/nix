#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: codex-mcp-init <mcp-name>
       codex-mcp-init --all

Authenticate one MCP server or every enabled HTTP MCP server in list order.
USAGE
}

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

case "$1" in
  --all)
    mapfile -t mcp_names < <(
      codex mcp list --json | jq -r '
        .[]
        | select(.enabled and .transport.type == "streamable_http")
        | .name
      '
    )

    if [ "${#mcp_names[@]}" -eq 0 ]; then
      echo "No enabled HTTP MCP servers found." >&2
      exit 1
    fi
    ;;
  -h | --help)
    usage
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
