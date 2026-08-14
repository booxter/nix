{ config, lib, ... }:
let
  pkiRootCaPath = config.host.pki.authority.rootCaCertificate;
  lanDomain = config.host.network.lanDomain;
  localServerAliasesFor = aliases: aliases ++ map (alias: "${alias}.local") aliases;
in
{
  options.host.internalHttps = {
    localAliases = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Single-label local service names exported by enabled internal HTTPS services.";
    };

    services = lib.mkOption {
      type =
        with lib.types;
        attrsOf (
          submodule (
            { name, config, ... }:
            {
              config.serverAliases = lib.mkBefore (localServerAliasesFor config.localAliases);

              options = {
                enable = lib.mkEnableOption "internal HTTPS service";

                serverName = lib.mkOption {
                  type = str;
                  default = "${name}.${lanDomain}";
                  description = "DNS name presented by the internal HTTPS vhost.";
                };

                serverAliases = lib.mkOption {
                  type = with lib.types; listOf str;
                  default = [ ];
                  description = "Additional internal hostnames served by the canonical internal HTTPS vhost.";
                };

                publicAliases = lib.mkOption {
                  type = with lib.types; listOf str;
                  default = [ ];
                  description = "Browser-facing hostnames served by sibling HTTPS vhosts with the same upstream and certificate.";
                };

                sans = lib.mkOption {
                  type = with lib.types; listOf str;
                  default = lib.unique (
                    [
                      name
                      config.serverName
                    ]
                    ++ config.serverAliases
                    ++ config.publicAliases
                  );
                  description = "DNS SANs to include when issuing this service certificate.";
                };

                localAliases = lib.mkOption {
                  type = with lib.types; listOf str;
                  default = [ name ];
                  description = "Single-label local service names to serve directly and as .local mDNS names.";
                };

                listenAddress = lib.mkOption {
                  type = str;
                  default = "0.0.0.0";
                  description = "Address for the internal HTTPS vhost to bind.";
                };

                port = lib.mkOption {
                  type = port;
                  default = 443;
                  description = "Port for the internal HTTPS vhost.";
                };

                path = lib.mkOption {
                  type = str;
                  default = "/";
                  description = "Path to expose through the HTTPS reverse proxy.";
                };

                upstream = lib.mkOption {
                  type = str;
                  description = "Loopback or private upstream URL for the internal HTTPS service.";
                };

                openFirewall = lib.mkOption {
                  type = bool;
                  default = true;
                  description = "Whether to open the firewall for the internal HTTPS service.";
                };

                proxyWebsockets = lib.mkOption {
                  type = bool;
                  default = true;
                  description = "Whether to enable websocket proxy headers.";
                };

                recommendedProxySettings = lib.mkOption {
                  type = bool;
                  default = true;
                  description = "Whether to apply NixOS nginx recommended proxy headers automatically.";
                };

                secretPrefix = lib.mkOption {
                  type = str;
                  default = "internal_https/${name}";
                  description = "SOPS key prefix containing server_crt_unencrypted and server_key for this service.";
                };

                locationExtraConfig = lib.mkOption {
                  type = lines;
                  default = "";
                  description = "Extra nginx location config for this service.";
                };

                mtls = {
                  enable = lib.mkEnableOption "client certificate authentication for this internal HTTPS service";

                  trustedCaCertificate = lib.mkOption {
                    type = path;
                    default = pkiRootCaPath;
                    description = "CA certificate bundle trusted for inbound client certificate verification.";
                  };
                };

                probe = {
                  enable = lib.mkEnableOption "probe-only internal HTTPS listener";

                  port = lib.mkOption {
                    type = port;
                    default = 9443;
                    description = "HTTPS port for exact backend probe locations; no catch-all upstream is exposed on this listener.";
                  };
                };
              };
            }
          )
        );
      default = { };
      description = "Internal HTTPS services fronted by nginx and backed by the internal PKI.";
    };
  };
}
