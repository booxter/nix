{
  config,
  lib,
  ...
}:
{
  imports = [
    ./inventory.nix
    ./node-exporter.nix
  ];

  options.host.observability = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.host.realm == "home";
      readOnly = true;
      internal = true;
      description = "Whether realm policy enables host-side observability services.";
    };

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
