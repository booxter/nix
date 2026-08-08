{
  config,
  hostInventory,
  lib,
  ...
}:
let
  freeDns = hostInventory.site.dynamicDns.freeDns;
  ingressServices = config.host.publicIngress.services;
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
    paperless = 12881;
    llm = 14000;
    ai = 14001;
    search = 18083;
    goo = 14444;
  };
  backendMtlsServices = builtins.mapAttrs (id: service: {
    clientName = id;
    inherit (service.backend) serverName;
    localPort = backendMtlsServicePorts.${id};
  }) (lib.filterAttrs (_: service: service.backend.type == "internal-https") ingressServices);
in
{
  host.internalPki.clients = builtins.mapAttrs (_: _: {
    enable = true;
    category = "internal";
    materializations.default.restartUnits = [ "stunnel.service" ];
  }) backendMtlsServices;

  # Keep public gateway config-only changes from dropping long-lived proxied streams.
  services.nginx.enableReload = true;

  host.externalService = {
    ddns = {
      enable = true;
      hostname = freeDns.records.beast;
      inherit (freeDns) username;
    };
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
              proxyPass = ingressServices.${service.id}.backend.url;
            };
      }) hostInventory.publicServices
    );
  };

}
