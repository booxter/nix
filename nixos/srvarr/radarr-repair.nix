{ config, ... }:
{
  host.radarr.repair.planner.enable = true;
  host.radarr.repair.worker = {
    enable = true;
    roots."root:downloads" = config.services.transmission.settings.download-dir;
  };

  host.pki.clients.radarr-repair-planner = {
    category = "internal";
    commonName = "radarr-repair-planner.${config.networking.hostName}";
  };
}
