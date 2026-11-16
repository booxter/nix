{ config, lib, ... }:
let
  client = config.host.pki.clients.tempo.materializations.default;
in
{
  options.host.observability.tracing.enable = lib.mkEnableOption "local OTLP trace collection";

  config = lib.mkIf config.host.observability.tracing.enable {
    services.alloy.enable = true;
    environment.etc."alloy/traces.alloy".text = import ./pipeline.nix {
      endpoint = "https://tempo.${config.host.network.lanDomain}";
      caFile = config.host.pki.authority.rootCaCertificate;
      certFile = "/run/credentials/alloy.service/tempo-client.crt";
      keyFile = "/run/credentials/alloy.service/tempo-client.key";
    };

    host.pki.clients.tempo = {
      category = "observability";
      secretPrefix = "observability/clients/tempo";
      materializations.default.restartUnits = [ "alloy.service" ];
    };
    systemd.services.alloy = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      serviceConfig.LoadCredential = [
        "tempo-client.crt:${client.certificatePath}"
        "tempo-client.key:${client.keyPath}"
      ];
    };
  };
}
