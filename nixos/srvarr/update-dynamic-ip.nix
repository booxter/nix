{
  lib,
  srvarrPkgs,
  utils,
  ...
}:
let
  cookiePath = "/data/.secret/mam.cookies";
  updateCommand = utils.escapeSystemdExecArgs [
    (lib.getExe srvarrPkgs.dynamic-ip-updater)
    "--cookie-jar"
    cookiePath
  ];
in
{
  systemd.services."update-dynamic-ip" = {
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
      ExecStart = updateCommand;
    };
  };

  systemd.timers."update-dynamic-ip" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "10m";
      Unit = "update-dynamic-ip.service";
    };
  };
}
