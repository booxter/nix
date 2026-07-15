{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.internalHttps;
  enabledClients = lib.filterAttrs (_: client: client.enable) cfg.mtlsClients;
  secretAttrName = clientName: "internal-https-client-${clientName}";
in
{
  options.host.internalHttps.mtlsClients = lib.mkOption {
    type =
      with lib.types;
      attrsOf (
        submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkEnableOption "internal HTTPS mTLS client identity";

              secretPrefix = lib.mkOption {
                type = str;
                default = "internal_https/clients/${name}";
                description = "SOPS key prefix containing client_crt_unencrypted and client_key for this client identity.";
              };

              commonName = lib.mkOption {
                type = str;
                default = "${name}.${config.host.dnsName}";
                description = "Leaf certificate common name to issue for this client identity.";
              };

              sans = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Optional SANs for this client certificate.";
              };

              owner = lib.mkOption {
                type = str;
                default = "root";
                description = "Owner for generated client certificate and key secret files.";
              };

              group = lib.mkOption {
                type = str;
                default = "root";
                description = "Group for generated client certificate and key secret files.";
              };

              mode = lib.mkOption {
                type = str;
                default = "0400";
                description = "Mode for generated client certificate and key secret files.";
              };

              restartUnits = lib.mkOption {
                type = listOf str;
                default = [ ];
                description = "Units restarted when this client certificate changes.";
              };
            };
          }
        )
      );
    default = { };
    description = "Internal HTTPS mTLS client identities used by services on this host.";
  };

  config.sops.secrets =
    lib.mapAttrs' (
      clientName: client:
      lib.nameValuePair "${secretAttrName clientName}-crt" (
        {
          key = "${client.secretPrefix}/client_crt_unencrypted";
          owner = client.owner;
          group = client.group;
          mode = client.mode;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          restartUnits = client.restartUnits;
        }
      )
    ) enabledClients
    // lib.mapAttrs' (
      clientName: client:
      lib.nameValuePair "${secretAttrName clientName}-key" (
        {
          key = "${client.secretPrefix}/client_key";
          owner = client.owner;
          group = client.group;
          mode = client.mode;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          restartUnits = client.restartUnits;
        }
      )
    ) enabledClients;
}
