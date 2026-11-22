{
  lib,
  pkgs,
  roots,
}:
let
  telemetry = import ../observability/tempo/paths.nix;
  rootArguments = lib.concatLists (
    lib.mapAttrsToList (id: path: [
      "--root"
      "${id}=${path}"
    ]) roots
  );
  bindArguments = lib.concatMap (path: [
    "--bind"
    path
    path
  ]) (builtins.attrValues roots);
in
# MKVToolNix needs a UTF-8 locale to open release paths containing non-ASCII characters.
pkgs.writeShellScript "repairr-media" ''
  exec ${lib.getExe pkgs.bubblewrap} \
    --unshare-all --die-with-parent --new-session --clearenv \
    --setenv LC_ALL C.UTF-8 \
    --ro-bind /nix/store /nix/store --dev /dev --proc /proc --tmpfs /tmp \
    --ro-bind-try ${telemetry.directory} ${telemetry.directory} \
    ${lib.escapeShellArgs bindArguments} \
    ${lib.getExe pkgs.media-repair-helper} ${lib.escapeShellArgs rootArguments} "$@"
''
