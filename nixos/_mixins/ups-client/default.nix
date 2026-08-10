{
  config,
  facts,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.ups;
  serverName = cfg.client.server;
  model = import ../../../common/_mixins/ups/model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  server = if serverName == null then null else model.servers.${serverName} or null;
  fleetNetwork = import ../../_lib/fleet-host-network.nix { inherit config outputs; };
  clientCredentialMode = facts.realms.${config.host.realm}.services.ups.credentialMode;
  serverCredentialMode =
    if server == null then null else facts.realms.${server.realm}.services.ups.credentialMode;
  monitorName = if serverName == null then "" else serverName;
  monitorSecret = "nut/monitors/${monitorName}/password";
  useLiteralPassword =
    server != null && (clientCredentialMode == "literal" || serverCredentialMode == "literal");
  passwordFile =
    if useLiteralPassword then "/etc/nut/upsclient.pass" else config.sops.secrets.${monitorSecret}.path;
  shutdownDelay = config.host.power.shutdown.delaySeconds;
in
{
  config = lib.mkIf (server != null) {
    host.ups.scheduler = lib.mkIf (shutdownDelay != null) {
      enable = true;
      inherit (cfg.shutdown) waitForLowBattery;
      shutdownDelaySeconds = shutdownDelay;
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
        system = "${server.ups.server.name}@${fleetNetwork.addressFor serverName}";
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
