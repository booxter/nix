{
  config,
  lib,
  storageIdentities,
  storageModel,
  ...
}:
let
  model = storageModel;
  resources = config.host.storage.resources;
  claims = config.host.storage.claims;
  resourceFsids = map (resource: resource.nfs.fsid) (
    builtins.attrValues (lib.filterAttrs (_: resource: resource.nfs != null) resources)
  );
  mountPoints = map (claim: claim.mountPoint) (builtins.attrValues claims);
  safeRelativePath =
    path:
    path != ""
    && !lib.hasPrefix "/" path
    && lib.all (component: component != "" && component != "." && component != "..") (
      lib.splitString "/" path
    );
  directoryDefinitionsAgree = definitions: builtins.length (lib.unique definitions) == 1;
  anonymousIdentities = lib.unique (
    lib.filter (name: name != null) (
      map (resource: if resource.nfs == null then null else resource.nfs.anonymousIdentity) (
        builtins.attrValues model.localResources
        ++ map (claim: claim.resolvedResource) (builtins.attrValues model.localClaims)
      )
    )
  );
in
{
  assertions = [
    {
      assertion = builtins.length mountPoints == builtins.length (lib.unique mountPoints);
      message = "host.storage.claims must use unique mount points";
    }
    {
      assertion = builtins.length resourceFsids == builtins.length (lib.unique resourceFsids);
      message = "NFS storage resources on ${model.hostName} must use unique FSIDs";
    }
  ]
  ++ lib.mapAttrsToList (name: resource: {
    assertion = builtins.hasAttr resource.volume config.host.storage.volumes;
    message = "host.storage.resources.${name} references unknown volume '${resource.volume}'";
  }) resources
  ++ lib.mapAttrsToList (name: resource: {
    assertion = safeRelativePath resource.relativePath || resource.relativePath == ".";
    message = "host.storage.resources.${name}.relativePath must be a safe relative path";
  }) resources
  ++ lib.concatMap (
    resource:
    lib.mapAttrsToList (path: _: {
      assertion = safeRelativePath path || path == ".";
      message = "storage resource ${resource.providerName}.${resource.resourceName} has unsafe directory path '${path}'";
    }) (resource.directories)
  ) (builtins.attrValues model.localResources)
  ++ lib.concatMap (
    claim:
    [
      {
        assertion = lib.hasPrefix "/" claim.mountPoint;
        message = "host.storage.claims.${claim.claimName}.mountPoint must be absolute";
      }
    ]
    ++ lib.mapAttrsToList (path: _: {
      assertion = safeRelativePath path || path == ".";
      message = "host.storage.claims.${claim.claimName} has unsafe directory path '${path}'";
    }) (claim.directories)
  ) (builtins.attrValues model.localClaims)
  ++ lib.mapAttrsToList (path: definitions: {
    assertion = directoryDefinitionsAgree definitions;
    message = "storage directory '${path}' has conflicting provisioning requests";
  }) model.directoriesByPath
  ++ lib.concatMap (
    name:
    let
      expected = storageIdentities.users.${name};
      user = config.users.users.${name} or null;
      group = config.users.groups.${expected.group} or null;
    in
    [
      {
        assertion = user != null && user.uid == expected.uid;
        message = "NFS anonymous identity ${name} must use UID ${toString expected.uid}";
      }
      {
        assertion = group != null && group.gid == storageIdentities.groups.${expected.group};
        message = "NFS anonymous identity ${name} must use the shared ${expected.group} GID";
      }
    ]
  ) anonymousIdentities;
}
