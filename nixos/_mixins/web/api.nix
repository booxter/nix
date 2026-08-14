{ config, lib, ... }:
let
  cfg = config.host.web.api;
  valid = lib.filterAttrs (_: api: builtins.hasAttr api.service config.host.web.services) cfg;
  allowConfig = api: lib.concatMapStringsSep "\n" (cidr: "allow ${cidr};") api.allowedCidrs;
in
{
  options.host.web.api = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            service = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = name;
              description = "Registered web service that owns the ${name} API.";
            };

            interface = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Concrete application API implemented by ${name}.";
            };

            path = lib.mkOption {
              type = lib.types.strMatching "^/.*";
              default = "/api/";
              description = "API path exposed to registered consumers.";
            };

            healthPath = lib.mkOption {
              type = lib.types.strMatching "^/.*";
              default = "/ping";
              description = "Unauthenticated application readiness path.";
            };

            localUnit = lib.mkOption {
              type = with lib.types; nullOr nonEmptyStr;
              default = null;
              description = "Local systemd unit implementing the API, when co-located.";
            };

            allowedCidrs = lib.mkOption {
              type = with lib.types; listOf nonEmptyStr;
              default = [ ];
              description = "Networks from which registered consumers reach this API.";
            };

            authentication.apiKey = {
              source = lib.mkOption {
                type = lib.types.strMatching "^/.*";
                description = "File from which systemd may load the API credential source.";
              };

              format = lib.mkOption {
                type = lib.types.enum [ "xml-element" ];
                default = "xml-element";
              };

              field = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Field containing the API key in the credential source.";
              };
            };
          };
        }
      )
    );
    default = { };
    description = "Authenticated application APIs available to host-local integrations.";
  };

  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList (name: api: {
        assertion = builtins.hasAttr api.service config.host.web.services;
        message = "host.web.api.${name}.service must select a web service";
      }) cfg;
    }
    {
      services.nginx.virtualHosts = lib.mkMerge (
        lib.mapAttrsToList (
          _: api:
          let
            service = config.host.web.services.${api.service};
          in
          {
            "internal-https-${service.internal.endpointName}-probe" = {
              locations."= ${api.healthPath}" = {
                proxyPass = service.upstream;
                recommendedProxySettings = true;
                extraConfig = ''
                  auth_request off;
                  ${allowConfig api}
                  deny all;
                '';
              };
            };
          }
        ) valid
      );
    }
  ];
}
