{ config, ... }:
{
  host.pki.clients.radarr-repair-planner = {
    category = "internal";
    commonName = "radarr-repair-planner.${config.networking.hostName}";
    materializations.default.restartUnits = [ "radarr-repair-planner.service" ];
  };
}
