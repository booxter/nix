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
pkgs.writeShellScript "repairr-media" ''
  exec ${lib.getExe pkgs.bubblewrap} \
    --unshare-all --die-with-parent --new-session --clearenv \
    --ro-bind /nix/store /nix/store --dev /dev --proc /proc --tmpfs /tmp \
    --ro-bind-try ${telemetry.directory} ${telemetry.directory} \
    ${lib.escapeShellArgs bindArguments} \
    ${lib.getExe pkgs.media-repair-helper} ${lib.escapeShellArgs rootArguments} "$@"
''
