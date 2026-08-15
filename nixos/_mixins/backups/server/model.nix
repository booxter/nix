{
  backupTopology,
  config,
  lib,
}:
let
  server = config.host.backups.server;
  cfg = if server == null then null else server // backupTopology.server;
in
rec {
  inherit cfg server;

  cloudGroup = "restic-cloud";
  dependencyUnits = [
    "network-online.target"
    "sops-install-secrets.service"
  ];
  requiredUnits = lib.optional (cfg.offsite != null && cfg.offsite.qos) "qos-wan.service";

  enabledOffloads = lib.filterAttrs (_: repository: repository.cloud.enable) cfg.repositories;
  credentialedOffloads = lib.filterAttrs (
    _: repository: repository.cloud.backend != "local"
  ) enabledOffloads;
  b2Offloads = lib.filterAttrs (
    _: repository: repository.cloud.storageProvider == "b2"
  ) enabledOffloads;
  sshRepositories = lib.filterAttrs (_: repository: repository.publicKey != null) cfg.repositories;

  ingestUser = name: "restic-${name}";
  repositoryPath = name: "${cfg.repositoryRoot}/${cfg.repositories.${name}.storageName}";
  offloadUser = name: if name == cfg.localClient then cloudGroup else "restic-${name}-offload";
  offloadService = name: "restic-${name}-cloud-offload";
  pruneService = name: "restic-${name}-cloud-prune";
  aclService = name: "restic-${name}-repo-acl";
  cloudStateDir = name: "restic-cloud-${name}";

  applicationKeyIdFile = config.sops.secrets."backup/restic/cloud/b2/applicationKeyId".path;
  applicationKeyFile = config.sops.secrets."backup/restic/cloud/b2/applicationKey".path;
}
