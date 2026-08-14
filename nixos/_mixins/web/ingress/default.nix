{
  config,
  fleetWebServices,
  lib,
  ...
}:
let
  cfg = config.host.web.ingress;
  publicServices = builtins.filter (
    contribution: contribution.value.public.ingressHost == config.networking.hostName
  ) fleetWebServices.public;
  mtlsPublicServices = builtins.filter (
    contribution: contribution.value.internal != null
  ) publicServices;
in
{
  imports = [ ./bandwidth-limits.nix ];

  options.host.web.ingress = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          acmeEmail = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "ihar.hrachyshka@gmail.com";
            description = "Email address used for public TLS certificate issuance.";
          };

          openFirewall = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to open public HTTP and HTTPS firewall ports.";
          };

          dynamicDns = {
            enable = lib.mkEnableOption "dynamic DNS for this ingress controller";

            hostname = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Dynamic DNS hostname updated by the ingress controller.";
            };

            username = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Dynamic DNS account username.";
            };
          };
        };
      }
    );
    default = null;
    description = "Public HTTPS ingress controller policy.";
  };

  config = lib.mkIf (cfg != null) {
    services.nginx.enableReload = true;

    host.pki.clients = builtins.listToAttrs (
      map (contribution: {
        name = contribution.id;
        value = {
          enable = true;
          category = "internal";
        };
      }) mtlsPublicServices
    );

    host.externalService = {
      inherit (cfg) acmeEmail openFirewall;
      ddns = {
        inherit (cfg.dynamicDns) enable hostname username;
      };
      virtualHosts = builtins.listToAttrs (
        map (contribution: {
          name = contribution.value.public.hostName;
          value =
            if contribution.value.internal != null then
              let
                service = contribution.value;
              in
              {
                proxyPass = service.internal.url;
                upstreamTls = {
                  enable = true;
                  clientName = contribution.id;
                  serverName = service.internal.serverName;
                };
                inherit (service.public) locationExtraConfig;
              }
            else
              {
                proxyPass = contribution.value.upstream;
                inherit (contribution.value.public) locationExtraConfig;
              };
        }) publicServices
      );
    };
  };
}
