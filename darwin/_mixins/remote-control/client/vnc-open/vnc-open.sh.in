usage() {
  cat <<'EOF'
Usage: vnc-open [--@usageDisplays@] [HOST]

Open macOS Screen Sharing for a host with a VNC server enabled.
If HOST is omitted, select one interactively.
Display selection applies only to tunneled multi-display hosts.

Hosts: @usageHosts@
EOF
}

target=""
requested_display=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
@displayOptionCases@
    -*)
      printf 'vnc-open: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$target" ]]; then
        printf 'vnc-open: expected exactly one host\n' >&2
        usage >&2
        exit 2
      fi
      target="$1"
      ;;
  esac
  shift
done

if [[ -z "$target" ]]; then
  if ! target="$(
    printf '%s\n' @hostArguments@ \
      | fzf --height=~100% --layout=reverse --prompt='VNC host> '
  )"; then
    exit 0
  fi
fi

case "$target" in
@directHostCases@
@tunneledHostCases@
  *)
    printf 'vnc-open: unsupported host: %s\n' "$target" >&2
    usage >&2
    exit 2
    ;;
esac

runtime_dir="$(mktemp -d /tmp/vnc-open.XXXXXX)"
control_socket="$runtime_dir/control"
cleanup() {
  if [[ -S "$control_socket" ]]; then
    ssh -S "$control_socket" -O exit "$target" >/dev/null 2>&1 || true
  fi
  rmdir "$runtime_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ssh \
  -M \
  -S "$control_socket" \
  -fN \
  -o ExitOnForwardFailure=yes \
  -L "127.0.0.1:$local_port:127.0.0.1:$remote_port" \
  "$target"

# A dedicated Screen Sharing process lets `open` wait for this session;
# the EXIT trap then closes the SSH control master and its forwarding.
/usr/bin/open -n -W "vnc://127.0.0.1:$local_port"
