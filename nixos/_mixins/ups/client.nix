{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.ups.client;
  model = import ../../../common/_mixins/ups/model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  server = if cfg.server == null then null else model.servers.${cfg.server} or null;
  siteNetwork = import ../../../common/_lib/site-network.nix { inherit config; };
  clientCredentialMode = config.host.ups.credentialMode;
  serverCredentialMode = if server == null then null else server.ups.credentialMode;
  monitorName = if cfg.server == null then "" else cfg.server;
  monitorSecret = "nut/monitors/${monitorName}/password";
  useLiteralPassword =
    server != null && (clientCredentialMode == "literal" || serverCredentialMode == "literal");
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
        system = "${server.ups.server.name}@${siteNetwork.addressFor cfg.server}";
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
