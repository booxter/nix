{
  beastPkgs,
  config,
  lib,
  utils,
  ...
}:
let
  jellyfinApiKeyFile = config.sops.secrets."jellyfin/apiKey".path;
  waitForJellyfinIdleCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' beastPkgs.jellyfin-tools "wait-for-jellyfin-idle")
    "--url"
    "http://127.0.0.1:8096"
    "--api-key-file"
    jellyfinApiKeyFile
  ];
in
{
  host.maintenance.guards.jellyfin-playback = {
    command = waitForJellyfinIdleCommand;
    before = [
      "upgrade"
      "switch"
      "reboot"
    ];
    waitIndefinitely = true;
  };
}
