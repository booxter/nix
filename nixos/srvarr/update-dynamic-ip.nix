{
  lib,
  namespace,
  srvarrPkgs,
  utils,
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
  host.vpn.clients.update-dynamic-ip.namespace = namespace;

  systemd.services."update-dynamic-ip" = {
    unitConfig = {
      Wants = [ "network-online.target" ];
      After = [ "network-online.target" ];
    };
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
      ExecStart = updateCommand;
    };
  };

  systemd.timers."update-dynamic-ip" = {
    wantedBy = [ "timers.target" ];
    # Keep the timer independent from namespace restarts so it remains
    # scheduled after the namespace comes back.
    unitConfig.After = [ "${namespace}.service" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "1h";
      RandomizedDelaySec = "10m";
      Unit = "update-dynamic-ip.service";
    };
  };
}
