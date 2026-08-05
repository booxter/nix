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
  # This is the authoritative activation gate. It runs after the new system is
  # built but before services are stopped or restarted, covering auto-upgrades
  # and manual `deploy --switch` operations without a check/build race.
  system.preSwitchChecks.jellyfinPlayback = ''
    if [ "''${2-}" = switch ]; then
      ${waitForJellyfinIdleCommand}
    fi
  '';

  # Avoid starting a potentially expensive unattended build while playback is
  # already active. The pre-switch check above repeats the check at activation.
  systemd.services.nixos-upgrade.serviceConfig = {
    ExecStartPre = [ waitForJellyfinIdleCommand ];
    TimeoutStartSec = "infinity";
  };

  # Critical hosts reboot separately from their daily auto-upgrade switch.
  systemd.services.nixos-weekly-reboot-if-needed.serviceConfig = {
    ExecStartPre = [ waitForJellyfinIdleCommand ];
    TimeoutStartSec = "infinity";
  };
}
