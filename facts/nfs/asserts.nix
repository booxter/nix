{
  facts,
  lib,
}:
raw:
let
  sharedStorage = facts.shared-storage;
  providers = builtins.attrValues raw.providers;
  providerStorageMatches = lib.all (
    providerName:
    lib.all (export: sharedStorage.resources.${export.storageName}.provider == providerName) (
      builtins.attrValues raw.providers.${providerName}.exports
    )
  ) (builtins.attrNames raw.providers);
  providerFsidsAreUnique = lib.all (
    provider:
    let
      fsids = map (export: export.fsid) (builtins.attrValues provider.exports);
    in
    builtins.length fsids == builtins.length (lib.unique fsids)
  ) providers;
  clientMountPointsAreUnique = lib.all (
    links:
    let
      mountPoints = map (link: link.mountPoint) (builtins.attrValues links);
    in
    builtins.length mountPoints == builtins.length (lib.unique mountPoints)
  ) (builtins.attrValues raw.links);
in
[
  {
    assertion = providerStorageMatches;
    message = "NFS exports and shared storage resources must use the same provider";
  }
  {
    assertion = providerFsidsAreUnique;
    message = "NFS providers must use unique export FSIDs";
  }
  {
    assertion = clientMountPointsAreUnique;
    message = "NFS clients must use unique mount points";
  }
]
