{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  serverName = fleetInventory.ups.clients.${config.networking.hostName} or null;
  server = if serverName == null then null else fleetInventory.ups.servers.${serverName};
  siteNetwork = import ../../../common/_lib/site-network.nix { inherit config; };
  monitorName = if serverName == null then "" else serverName;
  monitorSecret = "nut/monitors/${monitorName}/password";
  useLiteralPassword =
    server != null
    && import ../../../common/_mixins/ups/uses-literal-credentials.nix {
      clientRealm = config.host.realm;
      serverRealm = fleetInventory.hosts.${serverName}.realm;
    };
  passwordFile =
    if useLiteralPassword then "/etc/nut/upsclient.pass" else config.sops.secrets.${monitorSecret}.path;
in
{
  config = lib.mkIf (server != null) {
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
        system = "${server.deviceName}@${siteNetwork.addressFor serverName}";
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
