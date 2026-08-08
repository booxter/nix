{
  config,
  lib,
  ...
}:
let
  jellyfinCfg = config.services.jellyfin;
  cfg = jellyfinCfg.downloadLimiter;
  rateBytesPerSecond = cfg.rateMbit * 1000 * 1000 / 8;
  proxyHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Server $hostname;
  '';
in
{
  options.services.jellyfin.downloadLimiter = {
    enable = lib.mkEnableOption "external Jellyfin download rate limiting";

    publicHost = lib.mkOption {
      type = lib.types.str;
      description = "Public Jellyfin hostname whose downloads should be limited.";
    };

    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 18096;
      description = "Loopback port on which the download-limiting proxy listens.";
    };

    rateMbit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Shared external download limit in decimal megabits per second.";
    };

    unlimitedNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Networks exempt from the external download limit.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = jellyfinCfg.enable;
        message = "services.jellyfin.downloadLimiter requires services.jellyfin.enable.";
      }
    ];

    # Only original-file downloads use HAProxy's shared bandwidth bucket.
    # Playback and all other requests continue directly to Jellyfin.
    services.nginx.virtualHosts.${cfg.publicHost}.locations."~* ^/Items/[^/]+/Download/?$" = {
      proxyPass = "http://127.0.0.1:${toString cfg.proxyPort}";
      proxyWebsockets = false;
      recommendedProxySettings = false;
      extraConfig = proxyHeaders + ''
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
          bind 127.0.0.1:${toString cfg.proxyPort}
          default_backend jellyfin_download_backend

        backend jellyfin_download_backend
          stick-table type integer size 10 expire 1h store bytes_out_rate(1s)
          filter bwlim-out jellyfin_downloads limit ${toString rateBytesPerSecond} key be_id
          http-request set-var(txn.client_scope) str(external)
          http-request set-var(txn.client_scope) str(lan) if { req.hdr_ip(X-Real-IP) -m ip ${lib.concatStringsSep " " cfg.unlimitedNetworks} }
          http-response set-bandwidth-limit jellyfin_downloads if { var(txn.client_scope) -m str external }
          server jellyfin 127.0.0.1:${toString jellyfinCfg.localPort}
      '';
    };

    systemd.services.nginx = {
      wants = [ "haproxy.service" ];
      after = [ "haproxy.service" ];
    };
  };
}
