{
  config,
  hostInventory,
  lib,
  ...
}:
let
  rootConfig = config;
  cfg = config.host.llm.clients;
  realmLlm = hostInventory.realms.${config.host.realm}.services.llm or null;
  enabledClients = lib.filterAttrs (_: client: client.enable) cfg;
  identityNames = map (client: client.identityName) (builtins.attrValues enabledClients);
  endpointHost =
    if realmLlm == null then
      null
    else
      builtins.head (hostInventory.toInternalServiceHosts realmLlm.serviceId);
  clientType =
    { name, config, ... }:
    {
      options = {
        enable = lib.mkEnableOption "access to the realm LLM provider";

        localPort = lib.mkOption {
          type = lib.types.port;
          description = "Loopback port exposing the authenticated LLM connection.";
        };

        identityName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Internal PKI client identity used for this connection.";
        };

        commonName = lib.mkOption {
          type = lib.types.str;
          default = "${config.identityName}.${rootConfig.networking.hostName}";
          description = "Common name of the internal PKI client identity.";
        };

        url = lib.mkOption {
          type = lib.types.str;
          default = "http://127.0.0.1:${toString config.localPort}";
          readOnly = true;
          internal = true;
          description = "Loopback URL for the authenticated LLM connection.";
        };
      };
    };
in
{
  options.host.llm.clients = lib.mkOption {
    type = with lib.types; attrsOf (submodule clientType);
    default = { };
    description = "Authenticated local connections to the realm LLM provider.";
  };

  config = lib.mkIf (enabledClients != { }) {
    assertions = [
      {
        assertion = realmLlm != null;
        message = "LLM clients require a provider in the host's realm.";
      }
      {
        assertion = builtins.length identityNames == builtins.length (lib.unique identityNames);
        message = "LLM clients on one host must use distinct internal PKI identities.";
      }
    ];

    host.internalPki.clients = builtins.listToAttrs (
      lib.mapAttrsToList (_: client: {
        name = client.identityName;
        value = {
          enable = true;
          category = "internal";
          inherit (client) commonName;
          materializations.default.restartUnits = [ "stunnel.service" ];
        };
      }) enabledClients
    );

    services.stunnel = {
      enable = true;
      logLevel = lib.mkDefault "warning";
      user = null;
      group = null;
      clients = lib.mapAttrs (
        _: client:
        let
          identity = config.host.internalPki.clients.${client.identityName}.materializations.default;
        in
        {
          accept = "127.0.0.1:${toString client.localPort}";
          connect = "${endpointHost}:443";
          cert = config.sops.secrets.${identity.certificateSecretName}.path;
          key = config.sops.secrets.${identity.keySecretName}.path;
          checkHost = endpointHost;
          sni = endpointHost;
          CAFile = toString config.host.internalPki.rootCaCertificate;
          verifyChain = true;
          OCSPaia = false;
        }
      ) enabledClients;
    };

    systemd.services.stunnel = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
