{
  config,
  facts,
  lib,
  ...
}:
let
  jellyfinDownloadProxyPort = 18096;
  jellyfinDownloadRateBytesPerSecond = 5 * 1000 * 1000 / 8;
  jellyfinService = config.host.web.services.jellyfin;
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
        http-request set-var(txn.client_scope) str(lan) if { req.hdr_ip(X-Real-IP) -m ip 127.0.0.0/8 ::1 ${facts.site.lan.cidr} fe80::/10 fc00::/7 }
        http-response set-bandwidth-limit jellyfin_downloads if { var(txn.client_scope) -m str external }
        server jellyfin ${jellyfinBackend}
    '';
  };

  systemd.services.nginx = {
    wants = [ "haproxy.service" ];
    after = [ "haproxy.service" ];
  };

}
