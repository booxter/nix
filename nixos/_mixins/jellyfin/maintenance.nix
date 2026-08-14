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
    cfg.localUrl
    "--api-key-file"
    cfg.apiKeyFile
  ];
in
{
  config = lib.mkIf (cfg != null && cfg.maintenance.guardPlayback) {
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
