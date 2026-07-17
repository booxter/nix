{
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  darwinHostSpecs = lib.mapAttrsToList (
    name: spec: spec // { inherit name; }
  ) hostInventory.darwinHosts;
  allHostSpecs = darwinHostSpecs ++ hostInventory.nixosHostSpecs;
  vncHosts = builtins.filter (host: host.vnc.enable or false) allHostSpecs;
  directHosts = builtins.filter (host: !(host.vnc.sshTunnel or false)) vncHosts;
  tunneledHosts = builtins.filter (host: host.vnc.sshTunnel or false) vncHosts;

  hostNames = lib.sort builtins.lessThan (map (host: host.name) vncHosts);
  displayNames = lib.unique (
    lib.concatMap (host: map (display: display.name) host.hardware.displays) tunneledHosts
  );

  directHostPatterns = lib.concatStringsSep "|" (
    map (host: lib.escapeShellArg host.name) directHosts
  );
  displayOptionCases = lib.concatMapStringsSep "\n" (displayName: ''
    --${displayName})
      if [[ -n "$requested_display" ]]; then
        printf 'vnc-open: select only one display\n' >&2
        exit 2
      fi
      requested_display=${lib.escapeShellArg displayName}
      ;;
  '') displayNames;

  mkTunneledHostCase =
    host:
    let
      displays = host.hardware.displays;
      defaultDisplay = lib.findFirst (
        display: display.primary or false
      ) (builtins.head displays) displays;
      displayCases = lib.concatStringsSep "\n" (
        lib.imap0 (index: display: ''
          ${lib.escapeShellArg display.name})
            remote_port=${toString (host.vnc.basePort + index)}
            ;;
        '') displays
      );
    in
    ''
      ${lib.escapeShellArg host.name})
        selected_display="''${requested_display:-${defaultDisplay.name}}"
        case "$selected_display" in
      ${displayCases}
          *)
            printf 'vnc-open: %s has no display named %s\n' "$target" "$selected_display" >&2
            exit 2
            ;;
        esac
        local_port=$((remote_port + 10000))
        ;;
    '';

  tunneledHostCases = lib.concatMapStrings mkTunneledHostCase tunneledHosts;
  vncOpen = pkgs.writeShellApplication {
    name = "vnc-open";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.fzf
      pkgs.openssh
    ];
    text = ''
      usage() {
        cat <<'EOF'
      Usage: vnc-open [--${lib.concatStringsSep "|--" displayNames}] [HOST]

      Open macOS Screen Sharing for an inventory host with VNC enabled.
      If HOST is omitted, select one interactively.
      Display selection applies only to tunneled multi-display hosts.

      Hosts: ${lib.concatStringsSep ", " hostNames}
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
      ${displayOptionCases}
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
          printf '%s\n' ${lib.concatStringsSep " " (map lib.escapeShellArg hostNames)} \
            | fzf --height=~100% --layout=reverse --prompt='VNC host> '
        )"; then
          exit 0
        fi
      fi

      case "$target" in
      ${lib.optionalString (directHosts != [ ]) ''
        ${directHostPatterns})
          if [[ -n "$requested_display" ]]; then
            printf 'vnc-open: display selection does not apply to %s\n' "$target" >&2
            exit 2
          fi
          exec /usr/bin/open "vnc://$target"
          ;;
      ''}
      ${tunneledHostCases}
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
    '';
  };
in
{
  environment.systemPackages = [ vncOpen ];
}
