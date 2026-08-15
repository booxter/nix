{
  lib,
  pkgs,
  transmissionModel,
  utils,
  ...
}:
let
  model = transmissionModel;
  inherit (model) cfg;
  updater = cfg.dynamicIpUpdater;
  package = pkgs.callPackage ./pkgs/dynamic-ip-updater {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  serviceName = "update-dynamic-ip";
  updateCommand = utils.escapeSystemdExecArgs [
    (lib.getExe package)
    "--cookie-jar"
    updater.cookieJarFile
  ];
in
{
  config = lib.mkIf (cfg != null && updater != null && model.vpnNamespace != null) {
    host.vpn.clients.${serviceName}.namespace = model.vpnNamespaceName;

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
      unitConfig.After = [ "${model.vpnNamespaceName}.service" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "10m";
        Unit = "${serviceName}.service";
      };
    };
  };
}
