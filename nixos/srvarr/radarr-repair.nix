{
  config,
  transmissionModel,
  ...
}:
{
  host.radarr.repair.controller = {
    enable = true;
    transmissionUrl = transmissionModel.rpcUrl;
    apply = {
      enable = true;
      allowedActions = [
        "join_parts_v1"
        "manual_import_file_v1"
      ];
    };
  };

  host.observability.nodeExporter.textfile.directories.radarr-repair =
    config.host.radarr.repair.controller.metricsDirectory;

  host.radarr.repair.planner.enable = true;
  host.radarr.repair.worker = {
    enable = true;
    roots."root:downloads" = config.services.transmission.settings.download-dir;
    writableRoots = [ "root:downloads" ];
  };

  host.pki.clients.radarr-repair-planner = {
    category = "internal";
    commonName = "radarr-repair-planner.${config.networking.hostName}";
  };
}
