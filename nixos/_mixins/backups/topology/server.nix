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
      );

  requests = builtins.concatLists (lib.mapAttrsToList requestsFrom configurations);

  offsitePrefix =
    let
      bucketName = cfg.offsite.bucketName;
      parts =
        if bucketName == null then [ ] else lib.splitString "/${bucketName}" cfg.offsite.repositoryRoot;
    in
    if builtins.length parts == 2 then lib.removePrefix "/" (builtins.elemAt parts 1) else null;

  repositoryFor = request: {
    inherit (request) publicKey storageName;
    cloud = lib.optionalAttrs cfg.offsite.enable {
      inherit (cfg.offsite) backend storageProvider;
      enable = true;
      prefix = lib.concatStringsSep "/" (
        builtins.filter (component: component != "" && component != null) [
          offsitePrefix
          request.storageName
        ]
      );
      repository = "${cfg.offsite.repositoryRoot}/${request.storageName}";
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
    invalidB2Root =
      cfg.enable && cfg.offsite.enable && cfg.offsite.storageProvider == "b2" && offsitePrefix == null;
    multipleLocalClients = builtins.length localClients > 1;
  };
}
