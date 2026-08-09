{
  hostInventory,
  lib,
  ...
}:
{
  options.host.srvarrPaths = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    readOnly = true;
    description = "Shared srvarr media and state root paths.";
  };

  config.host.srvarrPaths = {
    mediaDir = hostInventory.nfs.links.srvarr.media.mountPoint;
    # Preserve the historical state root so backups and existing service state
    # continue to land in the same place.
    stateDir = "/data/.state/nixarr";
  };
}
