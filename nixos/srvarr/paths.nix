{
  hostInventory,
  lib,
  ...
}:
let
  mediaDir = "/data/media";
  projectPaths = builtins.mapAttrs (
    _: value: if builtins.isAttrs value then projectPaths value else "${mediaDir}/${value}"
  );
in
{
  options.host.srvarrPaths = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    readOnly = true;
    description = "Shared srvarr media and state root paths.";
  };

  config.host.srvarrPaths = {
    inherit mediaDir;
    # Preserve the historical state root so backups and existing service state
    # continue to land in the same place.
    stateDir = "/data/.state/nixarr";
  }
  // projectPaths hostInventory.storage.nfs.exports.media.layout;
}
