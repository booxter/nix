{
  lib,
  srvarrPkgs,
  utils,
  wgTimerDeps,
  wgUnitDepsBase,
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
    unitConfig = wgUnitDepsBase;
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
      ExecStart = updateCommand;
    };
    vpnConfinement = {
      enable = true;
      vpnNamespace = "wg";
    };
  };

  systemd.timers."update-dynamic-ip" = {
    wantedBy = [ "timers.target" ];
    # Keep the timer independent from wg restarts. The service itself remains
    # bound to wg.service, but the timer should stay scheduled so it can fire
    # again after the namespace comes back.
    unitConfig = wgTimerDeps;
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "10m";
      Unit = "update-dynamic-ip.service";
    };
  };
}
