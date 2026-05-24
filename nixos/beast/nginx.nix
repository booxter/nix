{ hostInventory, outputs, ... }:
let
  arrVmAddress = hostInventory.dhcpReservationsByHostname.prox-srvarrvm.ip;
  orgVmAddress = hostInventory.dhcpReservationsByHostname.prox-orgvm.ip;
  publicServiceBackendAddresses = {
    beast = "127.0.0.1";
    srvarr = arrVmAddress;
    org = orgVmAddress;
  };
  publicServicePorts = {
    jellyfin = 8096;
    jellyseerr = outputs.nixosConfigurations.prox-srvarrvm.config.services.seerr.port;
    aurral = outputs.nixosConfigurations.prox-srvarrvm.config.systemd.services.aurral.environment.PORT;
    audiobookshelf = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.audiobookshelf.port;
    shelfmark = outputs.nixosConfigurations.prox-srvarrvm.config.nixarr.shelfmark.port;
    vikunja = outputs.nixosConfigurations.prox-orgvm.config.services.vikunja.port;
  };
in
{
  host.externalService = {
    ddns = {
      enable = true;
      hostname = "ihrachyshka-beast.freeddns.org";
      username = "ihrachyshka";
    };
    mtlsClients.vikunja.enable = true;
    virtualHosts = builtins.listToAttrs (
      map (service: {
        name = service.publicHost;
        value =
          if service.id == "vikunja" then
            {
              proxyPass = "https://vikunja.${hostInventory.site.lan.domain}";
              upstreamTls = {
                enable = true;
                clientName = "vikunja";
                serverName = "vikunja.${hostInventory.site.lan.domain}";
              };
            }
          else
            {
              proxyPass = "http://${publicServiceBackendAddresses.${service.owner}}:${
                toString publicServicePorts.${service.id}
              }";
            };
      }) hostInventory.publicServices
    );
  };

  services.nginx.virtualHosts.${hostInventory.servicesById.aurral.publicHost}.locations."/".extraConfig =
    ''
      proxy_set_header X-Forwarded-For $remote_addr;
    '';
}
