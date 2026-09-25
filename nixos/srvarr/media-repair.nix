{
  config,
  lib,
  ...
}:
let
  downloads = import ../_mixins/downloads/model.nix { inherit config lib; };
  stagingDirectory = {
    owner = "media-repair-worker";
    group = "media";
    mode = "0700";
  };
  workspaceDirectory = stagingDirectory // {
    mode = "2750";
  };
in
{
  host.storage.claims.media.directories = {
    "${config.host.transmission.storage.relativePath}/.media-repair" = workspaceDirectory;
    "${config.host.transmission.storage.relativePath}/.media-repair/staged" = stagingDirectory;
    "${downloads.routes.radarr-usenet.storage.relativePath}/.media-repair" = workspaceDirectory;
    "${downloads.routes.radarr-usenet.storage.relativePath}/.media-repair/staged" = stagingDirectory;
  };

  host.radarr.repair.controller = {
    enable = true;
    downloadClients = [
      "transmission"
      "sabnzbd"
    ];
    apply = {
      enable = true;
      finalizeStaleQueue = true;
      allowedActions = [
        "join_parts_v1"
        "manual_import_file_v1"
        "remux_bluray_v1"
        "remux_dvd_v1"
      ];
      allowedDownloadClients = [
        "transmission"
        "sabnzbd"
      ];
    };
  };

  host.observability.nodeExporter.textfile.directories.radarr-repair =
    config.host.radarr.repair.controller.metricsDirectory;

  host.mediaRepair = {
    planner.enable = true;
    review.enable = true;
  };
  host.mediaRepair.worker = {
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
}
