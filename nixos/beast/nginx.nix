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
  jellyfinDownloadProxyPort = 18096;
  jellyfinDownloadRateBytesPerSecond = 5 * 1000 * 1000 / 8;
  jellyfinPublicHost = "jf.${hostInventory.site.public.domain}";
  jellyfinProxyHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
in
{
  # Keep public gateway config-only changes from dropping long-lived proxied streams.
  services.nginx.enableReload = true;

  # Send only original-file downloads through HAProxy, which provides a shared
  # bandwidth bucket. All other Jellyfin requests continue to go directly to
  # Jellyfin so playback is unaffected.
  services.nginx.virtualHosts.${jellyfinPublicHost}.locations."~* ^/Items/[^/]+/Download/?$" = {
    proxyPass = "http://127.0.0.1:${toString jellyfinDownloadProxyPort}";
    proxyWebsockets = false;
    recommendedProxySettings = false;
    extraConfig = jellyfinProxyHeaders + ''
      proxy_buffering off;
    '';
  };

  services.haproxy = {
    enable = true;
    config = ''
      global

      defaults
        mode http
        timeout connect 5s
        timeout client 1h
        timeout server 1h

      frontend jellyfin_download_frontend
        bind 127.0.0.1:${toString jellyfinDownloadProxyPort}
        default_backend jellyfin_download_backend

      backend jellyfin_download_backend
        stick-table type integer size 10 expire 1h store bytes_out_rate(1s)
        filter bwlim-out jellyfin_downloads limit ${toString jellyfinDownloadRateBytesPerSecond} key be_id
        http-request set-var(txn.client_scope) str(external)
        http-request set-var(txn.client_scope) str(lan) if { req.hdr_ip(X-Real-IP) -m ip 127.0.0.0/8 ::1 ${hostInventory.site.lan.cidr} fe80::/10 fc00::/7 }
        http-response set-bandwidth-limit jellyfin_downloads if { var(txn.client_scope) -m str external }
        server jellyfin 127.0.0.1:${toString publicServicePorts.jellyfin}
    '';
  };

  systemd.services.nginx = {
    wants = [ "haproxy.service" ];
    after = [ "haproxy.service" ];
  };

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
                + lib.optionalString (service.id == "notes") ''
                  proxy_buffer_size 128k;
                  proxy_buffers 4 256k;
                  proxy_busy_buffers_size 256k;
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
