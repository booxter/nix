{
  hostInventory,
  lib,
  outputs,
  ...
}:
let
  arrVmAddress = hostInventory.toNixosHostIpv4Address "srvarr";
  orgVmAddress = hostInventory.toNixosHostIpv4Address "org";
  backendMtlsServices = builtins.listToAttrs (
    map
      (
        { id, localPort }:
        {
          name = id;
          value = {
            clientName = id;
            serverName = "${id}.${hostInventory.site.lan.domain}";
            inherit localPort;
          };
        }
      )
      [
        {
          id = "seerr";
          localPort = 15055;
        }
        {
          id = "romm";
          localPort = 18080;
        }
        {
          id = "aurral";
          localPort = 13001;
        }
        {
          id = "audiobookshelf";
          localPort = 19292;
        }
        {
          id = "shelfmark";
          localPort = 18084;
        }
        {
          id = "vikunja";
          localPort = 13456;
        }
        {
          id = "paperless";
          localPort = 12881;
        }
        {
          id = "llm";
          localPort = 14000;
        }
      ]
  );
  publicServiceBackendAddresses = {
    beast = "127.0.0.1";
    srvarr = arrVmAddress;
    org = orgVmAddress;
  };
  publicServicePorts = {
    jellyfin = 8096;
    seerr = outputs.nixosConfigurations.srvarr.config.services.seerr.port;
    aurral = outputs.nixosConfigurations.srvarr.config.systemd.services.aurral.environment.PORT;
    audiobookshelf = outputs.nixosConfigurations.srvarr.config.services.audiobookshelf.port;
    shelfmark = outputs.nixosConfigurations.srvarr.config.services.shelfmark.environment.FLASK_PORT;
    vikunja = outputs.nixosConfigurations.org.config.services.vikunja.port;
    paperless = outputs.nixosConfigurations.org.config.services.paperless.port;
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
                inherit (backend)
                  clientName
                  serverName
                  localPort
                  ;
              };
              locationExtraConfig =
                lib.optionalString (service.id == "aurral") ''
                  proxy_set_header X-Forwarded-For $remote_addr;
                ''
                + lib.optionalString (service.id == "paperless") ''
                  client_max_body_size 512m;
                  proxy_read_timeout 300s;
                  proxy_send_timeout 300s;
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
