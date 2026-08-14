{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.jellyfin;
  tools = pkgs.callPackage ./packages/tools { };
  waitForIdle = utils.escapeSystemdExecArgs [
    (lib.getExe' tools "wait-for-jellyfin-idle")
    "--url"
    "http://127.0.0.1:8096"
    "--api-key-file"
    config.sops.secrets."jellyfin/apiKey".path
  ];
in
{
  config = lib.mkIf (cfg != null) {
    host.maintenance.guards.jellyfin-playback = {
      command = waitForIdle;
      before = [
        "upgrade"
        "switch"
        "reboot"
      ];
      waitIndefinitely = true;
    };
  };
}
