{
  hostInventory,
  lib,
  outputs,
  ...
}:
let
  arrVmAddress = hostInventory.dhcpReservationsByHostname.prox-srvarrvm.ip;
  orgVmAddress = hostInventory.dhcpReservationsByHostname.prox-orgvm.ip;
  backendMtlsServices = builtins.listToAttrs (
    map
      (id: {
        name = id;
        value = {
          clientName = id;
          serverName = "${id}.${hostInventory.site.lan.domain}";
        };
      })
      [
        "jellyseerr"
        "aurral"
        "audiobookshelf"
        "shelfmark"
        "vikunja"
      ]
  );
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
    mtlsClients = builtins.mapAttrs (_: _: {
      enable = true;
    }) backendMtlsServices;
    virtualHosts = builtins.listToAttrs (
      map (service: {
        name = service.publicHost;
        value =
          if builtins.hasAttr service.id backendMtlsServices then
            let
              backend = backendMtlsServices.${service.id};
            in
            {
              proxyPass = "https://${backend.serverName}";
              upstreamTls = {
                enable = true;
                inherit (backend) clientName serverName;
              };
              locationExtraConfig = lib.optionalString (service.id == "aurral") ''
                proxy_set_header X-Forwarded-For $remote_addr;
              '';
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

}
