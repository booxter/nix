{
  config,
  transmissionModel,
  ...
}:
{
  host.radarr.repair.controller = {
    enable = true;
    transmissionUrl = transmissionModel.rpcUrl;
  };

  host.observability.nodeExporter.textfile.directories.radarr-repair =
    config.host.radarr.repair.controller.metricsDirectory;

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
