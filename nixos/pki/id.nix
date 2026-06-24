{ hostInventory, ... }:
let
  idService = hostInventory.servicesById.id;
  ssoPlaceholderPort = 18085;
in
{
  services.nginx.virtualHosts."sso-placeholder" = {
    listen = [
      {
        addr = "127.0.0.1";
        port = ssoPlaceholderPort;
      }
    ];
    locations."/" = {
      extraConfig = ''
        default_type text/plain;
        return 200 "SSO endpoint placeholder\n";
      '';
    };
  };

  host.internalHttps.services.id = {
    enable = true;
    upstream = "http://127.0.0.1:${toString ssoPlaceholderPort}";
    serverAliases = [ idService.publicHost ];
    mtls.enable = true;
  };
}
