{
  config,
  lib,
  pkgs,
  ...
}:
let
  jellyfinExporterPort = 9594;
in
{
  sops.templates."jellyfin-exporter.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      JELLYFIN_ADDRESS=http://127.0.0.1:8096
      JELLYFIN_TOKEN=${config.sops.placeholder."jellyfin/apiKey"}
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
        (lib.getExe pkgs.jellyfin-exporter)
        "--web.listen-address=0.0.0.0:${toString jellyfinExporterPort}"
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

  networking.firewall.allowedTCPPorts = [ jellyfinExporterPort ];
}
