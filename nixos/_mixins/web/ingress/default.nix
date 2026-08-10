{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.web.ingress;
  fleetServices = import ../../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  publicServices = builtins.filter (
    contribution: contribution.value.public.ingressHost == config.networking.hostName
  ) fleetServices.public;
  mtlsPublicServices = builtins.filter (
    contribution: contribution.value.public.transport == "internal-mtls"
  ) publicServices;
in
{
  options.host.web.ingress = {
    enable = lib.mkEnableOption "public HTTPS ingress controller";

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

  config = lib.mkIf cfg.enable {
    services.nginx.enableReload = true;

    host.internalPki.clients = builtins.listToAttrs (
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
            if contribution.value.public.transport == "internal-mtls" then
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
                proxyPass = contribution.value.public.directUpstream;
                inherit (contribution.value.public) locationExtraConfig;
              };
        }) publicServices
      );
    };
  };
}
