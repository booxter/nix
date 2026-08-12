{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  destinationView = destination: {
    inherit (destination)
      enable
      publicKey
      server
      storageName
      user
      ;
    inherit (destination) check retention timerConfig;
  };
  hostView = hostConfig: {
    destinations = lib.mapAttrs (_: destinationView) hostConfig.host.backups.destinations;
    server = {
      inherit (hostConfig.host.backups.server)
        enable
        repositoryRoot
        ;
      cloudGroup = hostConfig.host.backups.server.cloud.group;
      offsite = {
        inherit (hostConfig.host.backups.server.offsite)
          backend
          bucketName
          enable
          repositoryRoot
          storageProvider
          ;
      };
    };
  };
  otherConfigurations = builtins.removeAttrs outputs.nixosConfigurations [ localHost ];
  hosts = lib.mapAttrs (_: configuration: hostView configuration.config) otherConfigurations // {
    ${localHost} = hostView config;
  };
  servers = lib.filterAttrs (_: host: host.server.enable) hosts;
  requests = builtins.filter (request: request.enable) (
    builtins.concatLists (
      lib.mapAttrsToList (
        clientName: host:
        lib.mapAttrsToList (
          destinationName: destination:
          destination
          // {
            inherit clientName destinationName;
          }
        ) host.destinations
      ) hosts
    )
  );
  unknownServers = builtins.filter (request: !builtins.hasAttr request.server servers) requests;
  validRequests = builtins.filter (request: builtins.hasAttr request.server servers) requests;
  remoteRequests = builtins.filter (request: request.clientName != request.server) validRequests;
  missingPublicKeys = builtins.filter (request: request.publicKey == null) remoteRequests;
  requestKeys = map (request: "${request.server}/${request.clientName}") validRequests;
  duplicateClientServers = lib.unique (
    builtins.filter (
      key: builtins.length (builtins.filter (candidate: candidate == key) requestKeys) > 1
    ) requestKeys
  );
  offsitePrefixFor =
    server:
    let
      bucketName = server.offsite.bucketName;
      parts =
        if bucketName == null then [ ] else lib.splitString "/${bucketName}" server.offsite.repositoryRoot;
    in
    if builtins.length parts == 2 then lib.removePrefix "/" (builtins.elemAt parts 1) else null;
  invalidB2RepositoryRoots = builtins.attrNames (
    lib.filterAttrs (
      _: host:
      host.server.offsite.enable
      && host.server.offsite.storageProvider == "b2"
      && offsitePrefixFor host.server == null
    ) servers
  );
  resolve =
    request:
    let
      server = servers.${request.server}.server;
      offsitePrefix = offsitePrefixFor server;
    in
    request
    // {
      ingestUser = "restic-${request.clientName}";
      repositoryPath = "${server.repositoryRoot}/${request.storageName}";
      transport = if request.clientName == request.server then "local" else "sftp";
      user = if request.clientName == request.server then server.cloudGroup else request.user;
      offsite = server.offsite // {
        prefix = lib.concatStringsSep "/" (
          builtins.filter (component: component != "" && component != null) [
            offsitePrefix
            request.storageName
          ]
        );
        repository = "${server.offsite.repositoryRoot}/${request.storageName}";
      };
    };
  resolvedRequests = map resolve validRequests;
  repositoryPaths = map (request: request.repositoryPath) resolvedRequests;
  duplicateRepositoryPaths = lib.unique (
    builtins.filter (
      path: builtins.length (builtins.filter (candidate: candidate == path) repositoryPaths) > 1
    ) repositoryPaths
  );
  requestsByClient = lib.groupBy (request: request.clientName) resolvedRequests;
  requestsByServer = lib.groupBy (request: request.server) resolvedRequests;
in
{
  inherit
    duplicateClientServers
    duplicateRepositoryPaths
    hosts
    invalidB2RepositoryRoots
    missingPublicKeys
    requestsByClient
    requestsByServer
    servers
    unknownServers
    ;
}
