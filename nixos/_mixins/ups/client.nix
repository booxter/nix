{
  config,
  hostInventory,
  hostSpec,
  lib,
  ...
}:
let
  serverName = config.host.ups.client.server;
  serverSpec = if serverName == null then null else hostInventory.nixosHosts.${serverName};
  clientCredentialMode = hostInventory.realms.${config.host.realm}.services.ups.credentialMode;
  serverCredentialMode =
    if serverSpec == null then
      null
    else
      hostInventory.realms.${serverSpec.realm}.services.ups.credentialMode;
  monitorName = if serverSpec == null then "" else serverSpec.name;
  monitorSecret = "nut/monitors/${monitorName}/password";
  useLiteralPassword =
    serverSpec != null && (clientCredentialMode == "literal" || serverCredentialMode == "literal");
  passwordFile =
    if useLiteralPassword then "/etc/nut/upsclient.pass" else config.sops.secrets.${monitorSecret}.path;
in
{
  options.host.ups.client.server = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = hostSpec.upsHost or null;
    readOnly = true;
    internal = true;
    description = "Inventory host providing this host's UPS service.";
  };

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
