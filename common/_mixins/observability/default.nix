{
  config,
  lib,
  ...
}:
{
  imports = [
    ./node-exporter.nix
    ./policy.nix
  ];

  options.host.observability = {
    loki.client = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            writeUrl = lib.mkOption {
              type = nonEmptyStr;
            };
            serverName = lib.mkOption {
              type = nonEmptyStr;
            };
            trustedCaCertificate = lib.mkOption {
              type = path;
            };
          };
        });
      default =
        if config.host.realm == "home" then
          {
            writeUrl = "https://loki.${config.host.network.lanDomain}/loki/api/v1/push";
            serverName = "loki.${config.host.network.lanDomain}";
            trustedCaCertificate = config.host.pki.authority.rootCaCertificate;
          }
        else
          null;
      readOnly = true;
      internal = true;
      description = "Realm Loki endpoint used by host log shippers.";
    };
  };

  config = lib.mkIf config.host.observability.enable {
    host.observability.nodeExporter.mtls.enable = lib.mkDefault true;
  };
}
