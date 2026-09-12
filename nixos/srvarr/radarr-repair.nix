{ config, ... }:
{
  host.radarr.repair.planner.enable = true;

  host.pki.clients.radarr-repair-planner = {
    category = "internal";
    commonName = "radarr-repair-planner.${config.networking.hostName}";
  };
}
