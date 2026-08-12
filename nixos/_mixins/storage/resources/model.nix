{
  config,
  lib,
  outputs,
}:
let
  accounts = config.host.accounts;
  hostName = config.networking.hostName;
  nodeConfig = nodeConfig: {
    inherit (nodeConfig.host.storage) claims resources volumes;
  };
  nodes =
    lib.mapAttrs (_: configuration: nodeConfig configuration.config) (
      removeAttrs outputs.nixosConfigurations [ hostName ]
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
    claim
    // {
      inherit claimName clientName;
      resolvedResource = resolveResource claim.provider claim.resource;
      local = claim.provider == clientName;
    };
  allClaims = lib.concatLists (
    lib.mapAttrsToList (
      clientName: node: lib.mapAttrsToList (normalizeClaim clientName) node.claims
    ) nodes
  );
  localClaims = lib.mapAttrs (normalizeClaim hostName) config.host.storage.claims;
  providedClaims = builtins.filter (claim: claim.provider == hostName) allClaims;
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
        if groupName == "root" || builtins.hasAttr groupName accounts.groups then
          groupName
        else
          throw "storage resource ${resource.providerName}.${resource.resourceName} directory '${path}' references unknown group '${groupName}'";
      ownerAccount = accounts.users.${ownerName} or null;
      owner =
        if ownerName == "root" then
          "root"
        else if ownerAccount != null then
          toString ownerAccount.uid
        else
          throw "storage resource ${resource.providerName}.${resource.resourceName} directory '${path}' references unknown owner '${ownerName}'";
    in
    {
      inherit group owner path;
      mode = if directory.mode == null then defaults.mode else directory.mode;
      enforce = if directory.enforce == null then defaults.enforce else directory.enforce;
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
  providedDirectories = resourceDirectories ++ claimedDirectories;
  directoriesByPath = lib.groupBy (directory: directory.absolutePath) providedDirectories;
  uniqueDirectories = map builtins.head (builtins.attrValues directoriesByPath);
  participatingResources =
    builtins.attrValues localResources
    ++ map (claim: claim.resolvedResource) (builtins.attrValues localClaims);
  identityGroupNames = lib.unique (
    lib.concatMap (resource: resource.identities.groups) (builtins.attrValues localResources)
    ++ lib.concatMap (
      resource: lib.optional (resource.sharedGroup != null) resource.sharedGroup
    ) participatingResources
  );
  identityUserNames = lib.unique (
    lib.concatMap (resource: resource.identities.users) (builtins.attrValues localResources)
  );
  managedGroups = builtins.listToAttrs (
    map (name: {
      inherit name;
      value.gid = accounts.groups.${name}.gid;
    }) identityGroupNames
  );
  managedUsers = builtins.listToAttrs (
    map (
      name:
      let
        account = accounts.users.${name};
      in
      {
        inherit name;
        value = {
          isSystemUser = true;
          inherit (account) group uid;
          home =
            localResources.${
              lib.findFirst (
                resourceName: builtins.elem name localResources.${resourceName}.identities.users
              ) null (builtins.attrNames localResources)
            }.sourcePath;
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
