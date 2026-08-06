{
  config,
  hostInventory,
  lib,
  ...
}:
let
  serverName = config.host.ups.client.server;
  serverSpec = if serverName == null then null else hostInventory.nixosHosts.${serverName};
  monitorName = if serverSpec == null then "" else serverSpec.name;
  monitorSecret = "nut/monitors/${monitorName}/password";
  useLiteralPassword =
    serverSpec != null
    && (config.host.isWork || hostInventory.secretDomainsByHost.${serverName} == "work");
  passwordFile =
    if useLiteralPassword then "/etc/nut/upsclient.pass" else config.sops.secrets.${monitorSecret}.path;
in
{
  config = lib.mkIf (serverSpec != null) {
    host.ups.scheduler = {
      enable = true;
      shutdownDelaySeconds = if config.host.isVM then 450 else 900;
    };

    environment.etc."nut/upsclient.pass" = lib.mkIf useLiteralPassword {
      text = "upsslave123\n";
      mode = "0600";
    };

    sops.secrets.${monitorSecret} = lib.mkIf (!useLiteralPassword) {
      mode = "0400";
      restartUnits = [ "upsmon.service" ];
    };

    power.ups = {
      enable = true;
      mode = "netclient";
      upsmon.monitor.${monitorName} = {
        system = "${hostInventory.toUpsName serverName}@${hostInventory.toHostIpv4Address serverSpec}";
        user = "upsslave";
        inherit passwordFile;
        type = "slave";
      };
    };

    # Netclient mode depends on network reachability to the UPS server.
    systemd.services.upsmon = {
      wants = [
        "network-online.target"
      ]
      ++ lib.optional (!useLiteralPassword) "sops-install-secrets.service";
      after = [
        "network-online.target"
      ]
      ++ lib.optional (!useLiteralPassword) "sops-install-secrets.service";
    };
  };
}
