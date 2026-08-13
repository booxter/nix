{
  config,
  lib,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg;
  updater = cfg.dynamicIpUpdater;
  serviceName = "update-dynamic-ip";
  updateCommand = utils.escapeSystemdExecArgs [
    (lib.getExe updater.package)
    "--cookie-jar"
    updater.cookieJarFile
  ];
in
{
  config = lib.mkIf (cfg.enable && updater.enable && model.vpnNamespace != null) {
    host.vpn.clients.${serviceName}.namespace = cfg.vpn.namespace;

    systemd.services.${serviceName} = {
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

    systemd.timers.${serviceName} = {
      wantedBy = [ "timers.target" ];
      # Keep the timer independent from namespace restarts so it remains
      # scheduled after the namespace comes back.
      unitConfig.After = [ "${cfg.vpn.namespace}.service" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "10m";
        Unit = "${serviceName}.service";
      };
    };
  };
}
