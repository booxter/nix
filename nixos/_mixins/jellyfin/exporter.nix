{
  config,
  lib,
  pkgs,
  ...
}:
let
  jellyfinCfg = config.services.jellyfin;
  cfg = jellyfinCfg.exporter;
in
{
  options.services.jellyfin.exporter = {
    enable = lib.mkEnableOption "Prometheus exporter for Jellyfin";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./pkgs/jellyfin-exporter { };
      description = "Jellyfin exporter package.";
    };

    jellyfinUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8096";
      description = "Jellyfin API URL queried by the exporter.";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 19594;
      description = "Loopback port on which the Jellyfin exporter listens.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9594;
      description = "Port exposing Jellyfin metrics through the observability proxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = jellyfinCfg.enable;
        message = "services.jellyfin.exporter requires services.jellyfin.enable.";
      }
    ];

    sops.templates."jellyfin-exporter.env" = {
      owner = "root";
      group = "root";
      mode = "0400";
      content = ''
        JELLYFIN_ADDRESS=${cfg.jellyfinUrl}
        JELLYFIN_TOKEN=${config.sops.placeholder.${jellyfinCfg.apiKey.sopsKey}}
      '';
    };

    systemd.services.jellyfin-exporter = {
      description = "Prometheus exporter for Jellyfin";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "jellyfin.service"
        "sops-install-secrets.service"
      ];
      after = [
        "network-online.target"
        "jellyfin.service"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        EnvironmentFile = config.sops.templates."jellyfin-exporter.env".path;
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe cfg.package)
          "--web.listen-address=127.0.0.1:${toString cfg.listenPort}"
          "--collector.transcoding"
        ];
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        Restart = "always";
        RestartSec = "5s";
      };
    };

    host.observability.prometheusEndpoints.jellyfin = {
      enable = true;
      port = cfg.port;
      upstream = "http://127.0.0.1:${toString cfg.listenPort}/metrics";
    };
  };
}
