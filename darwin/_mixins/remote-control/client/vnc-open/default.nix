{
  directHosts,
  lib,
  pkgs,
  tunneledHosts,
}:
let
  vncHosts = directHosts ++ tunneledHosts;
  hostNames = lib.sort builtins.lessThan (map (host: host.name) vncHosts);
  displayNames = lib.unique (
    lib.concatMap (host: map (display: display.name) host.vnc.displays) tunneledHosts
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
      displays = host.vnc.displays;
      defaultDisplay = lib.findFirst (display: display.primary) (builtins.head displays) displays;
      displayCases = lib.concatMapStringsSep "\n" (display: ''
        ${lib.escapeShellArg display.name})
          remote_port=${toString display.port}
          ;;
      '') displays;
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
  replacements = {
    usageDisplays = lib.concatStringsSep "|--" displayNames;
    usageHosts = lib.concatStringsSep ", " hostNames;
    hostArguments = lib.concatStringsSep " " (map lib.escapeShellArg hostNames);
    inherit displayOptionCases;
    directHostCases = lib.optionalString (directHosts != [ ]) ''
      ${lib.concatStringsSep "|" (map (host: lib.escapeShellArg host.name) directHosts)})
        if [[ -n "$requested_display" ]]; then
          printf 'vnc-open: display selection does not apply to %s\n' "$target" >&2
          exit 2
        fi
        exec /usr/bin/open "vnc://$target"
        ;;
    '';
    tunneledHostCases = lib.concatMapStrings mkTunneledHostCase tunneledHosts;
  };
in
pkgs.writeShellApplication {
  name = "vnc-open";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.fzf
    pkgs.openssh
  ];
  text = lib.replaceStrings (map (name: "@${name}@") (
    builtins.attrNames replacements
  )) (builtins.attrValues replacements) (builtins.readFile ./vnc-open.sh.in);
}
