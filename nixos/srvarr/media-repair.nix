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

  host.mediaRepair = {
    enable = true;
    roots = {
      "root:downloads" = config.services.transmission.settings.download-dir;
      "root:usenet-manual" = downloads.routes.radarr-usenet.path;
    };
  };
  host.observability.nodeExporter.textfile.directories.repairr =
    "/var/lib/prometheus-node-exporter-textfile/repairr";
}
