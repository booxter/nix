{
  config,
  lib,
  ...
}:
let
  downloads = import ../_mixins/downloads/model.nix { inherit config lib; };
in
{
  host.radarr.repair.controller = {
    enable = true;
    downloadClients = [
      "transmission"
      "sabnzbd"
    ];
    apply = {
      enable = true;
      allowedActions = [
        "join_parts_v1"
        "manual_import_file_v1"
      ];
      allowedDownloadClients = [
        "transmission"
        "sabnzbd"
      ];
    };
  };

  host.observability.nodeExporter.textfile.directories.radarr-repair =
    config.host.radarr.repair.controller.metricsDirectory;

  host.radarr.repair.planner.enable = true;
  host.radarr.repair.worker = {
    enable = true;
    roots = {
      "root:downloads" = config.services.transmission.settings.download-dir;
      "root:usenet-manual" = downloads.routes.radarr-usenet.path;
    };
    writableRoots = [
      "root:downloads"
      "root:usenet-manual"
    ];
  };

  host.pki.clients.radarr-repair-planner = {
    category = "internal";
    commonName = "radarr-repair-planner.${config.networking.hostName}";
  };
}
