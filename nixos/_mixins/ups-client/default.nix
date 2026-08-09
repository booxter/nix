{
  config,
  facts,
  lib,
  ...
}:
let
  cfg = config.host.ups;
  serverName = cfg.client.server;
  serverSpec = if serverName == null then null else facts.hosts.nixos.${serverName} or null;
  upsServer = if serverName == null then null else facts.ups.serversByName.${serverName} or null;
  clientCredentialMode = facts.realms.${config.host.realm}.services.ups.credentialMode;
  serverCredentialMode =
    if serverSpec == null then null else facts.realms.${serverSpec.realm}.services.ups.credentialMode;
  monitorName = if serverSpec == null then "" else serverSpec.name;
  monitorSecret = "nut/monitors/${monitorName}/password";
  useLiteralPassword =
    serverSpec != null && (clientCredentialMode == "literal" || serverCredentialMode == "literal");
  passwordFile =
    if useLiteralPassword then "/etc/nut/upsclient.pass" else config.sops.secrets.${monitorSecret}.path;
in
{
  config = lib.mkMerge [
    {
      assertions = lib.optionals (serverName != null) [
        {
          assertion = serverSpec != null;
          message = "host.ups.client.server must name a NixOS host";
        }
        {
          assertion = builtins.elem serverName facts.ups.servers;
          message = "host.ups.client.server must reference a UPS server declared in facts";
        }
      ];
    }
    (lib.mkIf (serverSpec != null && upsServer != null) {
      host.ups.scheduler = {
        enable = true;
        inherit (cfg.shutdown) critical;
        shutdownDelaySeconds = cfg.shutdown.delaySeconds;
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
          system = "${upsServer.name}@${upsServer.address}";
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
    })
  ];
}
