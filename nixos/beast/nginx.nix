{
  hostInventory,
  lib,
  outputs,
  ...
}:
let
  arrVmAddress = hostInventory.toNixosHostIpv4Address "srvarr";
  orgVmAddress = hostInventory.toNixosHostIpv4Address "org";
  backendMtlsServicePorts = {
    id = 18443;
    dash = 18081;
    seerr = 15055;
    romm = 18080;
    aurral = 13001;
    audiobookshelf = 19292;
    pinepods = 18040;
    shelfmark = 18084;
    vikunja = 13456;
    notes = 18086;
    paperless = 12881;
    llm = 14000;
    ai = 14001;
    search = 18083;
  };
  backendMtlsServices = builtins.mapAttrs (id: localPort: {
    clientName = id;
    serverName = "${id}.${hostInventory.site.lan.domain}";
    inherit localPort;
  }) backendMtlsServicePorts;
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
    pinepods =
      outputs.nixosConfigurations.srvarr.config.systemd.services.podman-pinepods.environment.PINEPODS_LISTEN_PORT;
    shelfmark = outputs.nixosConfigurations.srvarr.config.services.shelfmark.environment.FLASK_PORT;
    vikunja = outputs.nixosConfigurations.org.config.services.vikunja.port;
    paperless = outputs.nixosConfigurations.org.config.services.paperless.port;
  };
in
{
  # Keep public gateway config-only changes from dropping long-lived proxied streams.
  services.nginx.enableReload = true;

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
