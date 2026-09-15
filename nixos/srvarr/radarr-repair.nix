{
  config,
  lib,
  ...
}:
let
  downloads = import ../_mixins/downloads/model.nix { inherit config lib; };
  stagingDirectory = {
    owner = "radarr-repair-worker";
    group = "media";
    mode = "0700";
  };
in
{
  host.storage.claims.media.directories = {
    "${config.host.transmission.storage.relativePath}/.radarr-repair" = stagingDirectory;
    "${downloads.routes.radarr-usenet.storage.relativePath}/.radarr-repair" = stagingDirectory;
  };

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
