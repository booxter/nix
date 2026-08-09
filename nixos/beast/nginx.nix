{
  config,
  hostInventory,
  lib,
  outputs,
  ...
}:
let
  fleetServices = import ../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  publicServices = builtins.filter (
    contribution: contribution.value.public.ingressHost == config.networking.hostName
  ) fleetServices.public;
  mtlsPublicServices = builtins.filter (
    contribution: contribution.value.public.transport == "internal-mtls"
  ) publicServices;
  jellyfinDownloadProxyPort = 18096;
  jellyfinDownloadRateBytesPerSecond = 5 * 1000 * 1000 / 8;
  jellyfinService = fleetServices.byId.jellyfin;
  jellyfinBackend = lib.removePrefix "http://" jellyfinService.public.directUpstream;
  jellyfinPublicHost = jellyfinService.public.hostName;
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
  host.internalPki.clients = builtins.listToAttrs (
    map (contribution: {
      name = contribution.id;
      value = {
        enable = true;
        category = "internal";
        materializations.default.restartUnits = [ "nginx.service" ];
      };
    }) mtlsPublicServices
  );

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
        server jellyfin ${jellyfinBackend}
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

}
