{
  backups,
  config,
  configurations,
  hostName,
  lib,
}:
let
  cfg = backups.server;
  cloudGroup = "restic-cloud";

  requestsFrom =
    clientName: configuration:
    let
      destination = configuration.config.host.backups.destination;
    in
    lib.optional (destination != null && destination.server == hostName) (
      destination
      // {
        inherit clientName;
      }
    );

  requests = builtins.concatLists (lib.mapAttrsToList requestsFrom configurations);

  joinPath =
    components: lib.concatStringsSep "/" (builtins.filter (component: component != "") components);

  offsiteRepository =
    storageName:
    let
      offsite = cfg.offsite;
      path = joinPath [
        offsite.prefix
        storageName
      ];
    in
    if offsite.backend == "s3" && offsite.endpoint != null then
      "s3:${offsite.endpoint}/${offsite.bucket}/${path}"
    else if offsite.backend == "b2" then
      "b2:${offsite.bucket}:${path}"
    else
      "";

  repositoryFor = request: {
    inherit (request) publicKey storageName;
    cloud = lib.optionalAttrs (cfg.offsite != null) {
      inherit (cfg.offsite) backend storageProvider;
      enable = true;
      prefix = joinPath [
        cfg.offsite.prefix
        request.storageName
      ];
      repository = offsiteRepository request.storageName;
      sourcePasswordFile =
        config.sops.secrets."backup/restic/${request.clientName}/cloud/localPassword".path;
      passwordFile = config.sops.secrets."backup/restic/${request.clientName}/cloud/password".path;
    };
  };

  repositories = builtins.listToAttrs (
    map (request: {
      name = request.clientName;
      value = repositoryFor request;
    }) requests
  );

  localClients = map (request: request.clientName) (
    builtins.filter (request: request.clientName == hostName) requests
  );
  localClient = if localClients == [ ] then null else builtins.head localClients;

  duplicateRepositoryPaths = builtins.attrNames (
    lib.filterAttrs (_: group: builtins.length group > 1) (
      lib.groupBy (request: "${cfg.repositoryRoot}/${request.storageName}") requests
    )
  );
in
{
  inherit localClient repositories;

  offloadUsers = map (name: if name == localClient then cloudGroup else "restic-${name}-offload") (
    builtins.attrNames repositories
  );

  errors = {
    inherit duplicateRepositoryPaths;
    multipleLocalClients = builtins.length localClients > 1;
  };
}
