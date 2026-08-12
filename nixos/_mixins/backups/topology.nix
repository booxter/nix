{
  config,
  lib,
  outputs ? {
    nixosConfigurations = { };
  },
  ...
}:
let
  hostName = config.networking.hostName;
  cloudGroup = "restic-cloud";
  cfg = config.host.backups;
  configurations = outputs.nixosConfigurations // {
    ${hostName}.config = config;
  };
  enabledDestinations = lib.filterAttrs (_: destination: destination.enable) cfg.destinations;
  knownDestinations = lib.filterAttrs (
    _: destination: builtins.hasAttr destination.server configurations
  ) enabledDestinations;
  enabledServerFor =
    destination:
    let
      server = configurations.${destination.server}.config.host.backups.server;
    in
    lib.optionalAttrs server.enable server;
  validDestinations = lib.filterAttrs (
    _: destination: (enabledServerFor destination) != { }
  ) knownDestinations;
  offsitePrefixFor =
    server:
    let
      bucketName = server.offsite.bucketName;
      parts =
        if bucketName == null then [ ] else lib.splitString "/${bucketName}" server.offsite.repositoryRoot;
    in
    if builtins.length parts == 2 then lib.removePrefix "/" (builtins.elemAt parts 1) else null;
  resolveDestination =
    _: destination:
    let
      server = enabledServerFor destination;
      local = destination.server == hostName;
    in
    {
      ingestUser = "restic-${hostName}";
      repositoryPath = "${server.repositoryRoot}/${destination.storageName}";
      transport = if local then "local" else "sftp";
      user = if local then cloudGroup else destination.user;
    };
  resolvedDestinations = lib.mapAttrs resolveDestination validDestinations;
  incomingRequests = builtins.concatLists (
    lib.mapAttrsToList (
      clientName: configuration:
      lib.mapAttrsToList
        (
          destinationName: destination:
          destination
          // {
            inherit clientName destinationName;
          }
        )
        (
          lib.filterAttrs (
            _: destination: destination.enable && destination.server == hostName
          ) configuration.config.host.backups.destinations
        )
    ) configurations
  );
  repositoryFor =
    request:
    let
      offsitePrefix = offsitePrefixFor cfg.server;
    in
    {
      inherit (request) publicKey storageName;
      cloud = lib.optionalAttrs cfg.server.offsite.enable {
        inherit (cfg.server.offsite) backend storageProvider;
        enable = true;
        prefix = lib.concatStringsSep "/" (
          builtins.filter (component: component != "" && component != null) [
            offsitePrefix
            request.storageName
          ]
        );
        repository = "${cfg.server.offsite.repositoryRoot}/${request.storageName}";
        sourcePasswordFile =
          config.sops.secrets."backup/restic/${request.clientName}/cloud/localPassword".path;
        passwordFile = config.sops.secrets."backup/restic/${request.clientName}/cloud/password".path;
      };
    };
  repositories = builtins.listToAttrs (
    map (request: {
      name = request.clientName;
      value = repositoryFor request;
    }) incomingRequests
  );
  localClients = map (request: request.clientName) (
    builtins.filter (request: request.clientName == hostName) incomingRequests
  );
  localClient = if localClients == [ ] then null else builtins.head localClients;
  duplicates =
    values:
    builtins.attrNames (
      lib.filterAttrs (_: group: builtins.length group > 1) (lib.groupBy (value: value) values)
    );
  destinationServers = map (destination: destination.server) (
    builtins.attrValues enabledDestinations
  );
  duplicateDestinationServers = duplicates destinationServers;
  repositoryPaths = map (
    request: "${cfg.server.repositoryRoot}/${request.storageName}"
  ) incomingRequests;
  duplicateRepositoryPaths = duplicates repositoryPaths;
  unknownDestinations = lib.filterAttrs (
    _: destination:
    !builtins.hasAttr destination.server configurations
    || !configurations.${destination.server}.config.host.backups.server.enable
  ) enabledDestinations;
  remoteDestinationsWithoutKeys = lib.filterAttrs (
    _: destination: destination.server != hostName && destination.publicKey == null
  ) enabledDestinations;
  missingPublicKeys = lib.mapAttrsToList (
    name: destination: "${hostName}.${name} -> ${destination.server}"
  ) remoteDestinationsWithoutKeys;
  unknownServers = lib.mapAttrsToList (
    name: destination: "${hostName}.${name} -> ${destination.server}"
  ) unknownDestinations;
  invalidB2Root =
    cfg.server.enable
    && cfg.server.offsite.enable
    && cfg.server.offsite.storageProvider == "b2"
    && offsitePrefixFor cfg.server == null;
  cloudQosEnabled = cfg.server.enable && cfg.server.offsite.enable && cfg.server.offsite.qos.enable;
in
{
  config = lib.mkMerge [
    {
      host.backups.internal.destinations = resolvedDestinations;

      host.backups.server = lib.mkIf cfg.server.enable { inherit localClient repositories; };

      host.qos.interfaces.wan = lib.mkIf cloudQosEnabled {
        device = config.host.network.primaryInterface;
        limits.cloud-backup = {
          rateMbit = config.host.site.policies.backups.maxUploadMbit;
          match.users = map (name: if name == localClient then cloudGroup else "restic-${name}-offload") (
            builtins.attrNames repositories
          );
        };
      };
    }
    (import ./topology/assertions.nix {
      inherit
        duplicateDestinationServers
        duplicateRepositoryPaths
        invalidB2Root
        lib
        localClients
        missingPublicKeys
        unknownServers
        ;
      serverEnabled = cfg.server.enable;
    })
  ];
}
