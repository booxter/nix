{
  config,
  lib,
  storageConfigurations,
  storageIdentities,
}:
let
  identities = storageIdentities;
  hostName = config.networking.hostName;
  nodeConfig = nodeConfig: {
    inherit (nodeConfig.host.storage) claims resources volumes;
  };
  nodes =
    lib.mapAttrs (_: configuration: nodeConfig configuration.config) (
      removeAttrs storageConfigurations [ hostName ]
    )
    // {
      ${hostName} = nodeConfig config;
    };
  resolveResource =
    providerName: resourceName:
    let
      provider = nodes.${providerName} or (throw "unknown storage provider '${providerName}'");
      resource =
        provider.resources.${resourceName}
          or (throw "storage provider '${providerName}' has no resource '${resourceName}'");
      volume =
        provider.volumes.${resource.volume}
          or (throw "storage resource ${providerName}.${resourceName} references unknown volume '${resource.volume}'");
    in
    resource
    // {
      inherit providerName resourceName;
      sourcePath =
        if resource.relativePath == "." then
          volume.mountPoint
        else
          "${volume.mountPoint}/${resource.relativePath}";
      backingMount = volume.mountPoint;
    };
  normalizeClaim =
    clientName: claimName: claim:
    let
      local = claim.provider == clientName;
      resolvedResource = resolveResource claim.provider claim.resource;
    in
    if !local && resolvedResource.nfs == null then
      throw "remote storage claim ${clientName}.${claimName} requires NFS on ${claim.provider}.${claim.resource}"
    else
      claim
      // {
        inherit
          claimName
          clientName
          local
          resolvedResource
          ;
      };
  allClaims = lib.concatLists (
    lib.mapAttrsToList (
      clientName: node: lib.mapAttrsToList (normalizeClaim clientName) node.claims
    ) nodes
  );
  localClaims = lib.mapAttrs (normalizeClaim hostName) config.host.storage.claims;
  localAttachments = builtins.concatLists (
    lib.mapAttrsToList (
      claimName: claim:
      lib.mapAttrsToList (unit: _: {
        inherit claimName unit;
        inherit (claim) mountPoint;
      }) claim.attachments
    ) localClaims
  );
  providedClaims =
    # Only providers need the fleet-wide claim view. Keep this guard lazy so
    # clients do not evaluate every host merely to discover they provide none.
    if config.host.storage.resources == { } then
      [ ]
    else
      builtins.filter (claim: claim.provider == hostName) allClaims;
  providedRemoteClaims = builtins.filter (claim: !claim.local) providedClaims;
  localResources = lib.mapAttrs (
    resourceName: _: resolveResource hostName resourceName
  ) config.host.storage.resources;
  normalizeDirectory =
    resource: path: directory:
    let
      defaults = resource.directoryDefaults;
      ownerName = if directory.owner == null then defaults.owner else directory.owner;
      groupName = if directory.group == null then defaults.group else directory.group;
      group =
        if groupName == "root" || builtins.hasAttr groupName identities.groups then
          groupName
        else
          throw "storage resource ${resource.providerName}.${resource.resourceName} directory '${path}' references unknown group '${groupName}'";
      ownerIdentity = identities.users.${ownerName} or null;
      owner =
        if ownerName == "root" then
          "root"
        else if ownerIdentity != null then
          toString ownerIdentity.uid
        else
          throw "storage resource ${resource.providerName}.${resource.resourceName} directory '${path}' references unknown owner '${ownerName}'";
    in
    {
      inherit
        group
        groupName
        owner
        ownerName
        path
        ;
      inherit (resource) resourceName;
      mode = if directory.mode == null then defaults.mode else directory.mode;
      absolutePath = if path == "." then resource.sourcePath else "${resource.sourcePath}/${path}";
    };
  resourceDirectories = lib.concatLists (
    lib.mapAttrsToList (
      _: resource: lib.mapAttrsToList (normalizeDirectory resource) resource.directories
    ) localResources
  );
  claimedDirectories = lib.concatMap (
    claim: lib.mapAttrsToList (normalizeDirectory claim.resolvedResource) claim.directories
  ) providedClaims;
  localClaimDirectories = lib.concatMap (
    claim: lib.mapAttrsToList (normalizeDirectory claim.resolvedResource) claim.directories
  ) (builtins.attrValues localClaims);
  providedDirectories = resourceDirectories ++ claimedDirectories;
  directoriesByPath = lib.groupBy (directory: directory.absolutePath) providedDirectories;
  uniqueDirectories = map builtins.head (builtins.attrValues directoriesByPath);
  participatingResources =
    builtins.attrValues localResources
    ++ map (claim: claim.resolvedResource) (builtins.attrValues localClaims);
  identityGroupNames = lib.unique (
    builtins.filter (name: name != "root") (
      map (resource: resource.directoryDefaults.group) participatingResources
      ++ map (directory: directory.groupName) (providedDirectories ++ localClaimDirectories)
    )
  );
  identityUserNames = lib.unique (
    builtins.filter (name: name != "root") (
      map (resource: resource.directoryDefaults.owner) (builtins.attrValues localResources)
      ++ map (directory: directory.ownerName) resourceDirectories
    )
  );
  managedGroups = builtins.listToAttrs (
    map (name: {
      inherit name;
      value.gid = identities.groups.${name};
    }) identityGroupNames
  );
  managedUsers = builtins.listToAttrs (
    map (
      name:
      let
        identity = identities.users.${name};
        resource = lib.findFirst (
          candidate:
          candidate.directoryDefaults.owner == name
          || lib.any (
            directory: directory.resourceName == candidate.resourceName && directory.ownerName == name
          ) resourceDirectories
        ) (throw "storage identity '${name}' has no owning resource") (builtins.attrValues localResources);
      in
      {
        inherit name;
        value = {
          isSystemUser = true;
          inherit (identity) group uid;
          home = resource.sourcePath;
          createHome = false;
        };
      }
    ) identityUserNames
  );
in
{
  inherit
    allClaims
    directoriesByPath
    hostName
    localAttachments
    localClaims
    localResources
    managedGroups
    managedUsers
    nodes
    providedClaims
    providedDirectories
    providedRemoteClaims
    resolveResource
    uniqueDirectories
    ;
}
