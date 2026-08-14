{
  backupTopology,
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  model = import ./model.nix { inherit backupTopology config lib; };
  inherit (model)
    aclService
    applicationKeyFile
    applicationKeyIdFile
    cfg
    cloudStateDir
    credentialedOffloads
    dependencyUnits
    enabledOffloads
    offloadService
    offloadUser
    pruneService
    repositoryPath
    requiredUnits
    server
    sshRepositories
    ;

  backupServerTools = pkgs.callPackage ../pkgs/backup-server-tools { };
  resticTools = pkgs.callPackage ../pkgs/restic-tools {
    atomicFileWrites = pkgs.atomic-file-writes;
  };
  command = executable: arguments: utils.escapeSystemdExecArgs ([ executable ] ++ arguments);

  aclConfig =
    name:
    (pkgs.formats.json { }).generate "${aclService name}.json" {
      repository = repositoryPath name;
      user = offloadUser name;
      setfaclExecutable = lib.getExe' pkgs.acl "setfacl";
    };

  cloudConfig =
    name:
    let
      repository = cfg.repositories.${name};
    in
    (pkgs.formats.json { }).generate "restic-${name}-cloud.json" (
      {
        backend = repository.cloud.backend;
        sourceRepository = repositoryPath name;
        sourcePasswordFile = repository.cloud.sourcePasswordFile;
        destinationRepository = repository.cloud.repository;
        destinationPasswordFile = repository.cloud.passwordFile;
        packSizeMib = 16;
        pruneOptions = repository.cloud.pruneOpts;
      }
      // lib.optionalAttrs (builtins.hasAttr name credentialedOffloads) {
        inherit applicationKeyFile applicationKeyIdFile;
        backendConnections = 2;
      }
    );

  cloudService =
    name: description: executable:
    let
      aclDependency = lib.optional (builtins.hasAttr name sshRepositories) "${aclService name}.service";
    in
    {
      inherit description;
      restartIfChanged = false;
      stopIfChanged = false;
      wants = dependencyUnits ++ aclDependency;
      requires = requiredUnits;
      after = dependencyUnits ++ requiredUnits ++ aclDependency;
      unitConfig.RequiresMountsFor = cfg.repositoryRoot;
      serviceConfig = {
        Type = "oneshot";
        User = offloadUser name;
        Group = offloadUser name;
        StateDirectory = cloudStateDir name;
        Environment = "RESTIC_CACHE_DIR=/var/lib/${cloudStateDir name}/cache";
        ExecStart = command executable [
          "--config"
          (cloudConfig name)
        ];
      };
    };
in
{
  config = lib.mkIf (server != null) {
    systemd.tmpfiles.rules = lib.optional (
      enabledOffloads != { }
    ) "d /var/lib/prometheus-node-exporter-textfile 0755 root root - -";

    systemd.services =
      lib.mapAttrs' (
        name: _:
        lib.nameValuePair (aclService name) {
          description = "Grant cloud offload access to the ${name} Restic repository";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          unitConfig.RequiresMountsFor = cfg.repositoryRoot;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = command (lib.getExe' backupServerTools "restic-repo-acl") [
              "--config"
              (aclConfig name)
            ];
          };
        }
      ) (lib.filterAttrs (name: _: builtins.hasAttr name sshRepositories) enabledOffloads)
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair (offloadService name) (
          cloudService name "Offload ${name} Restic repository to the cloud" (
            lib.getExe' resticTools "restic-cloud-offload"
          )
        )
      ) enabledOffloads
      // lib.mapAttrs' (
        name: _:
        lib.nameValuePair (pruneService name) (
          cloudService name "Prune ${name} cloud Restic repository" (
            lib.getExe' resticTools "restic-cloud-prune"
          )
        )
      ) enabledOffloads;

    systemd.timers =
      lib.mapAttrs' (
        name: repository:
        lib.nameValuePair (offloadService name) {
          wantedBy = [ "timers.target" ];
          timerConfig = repository.cloud.timerConfig;
        }
      ) enabledOffloads
      // lib.mapAttrs' (
        name: repository:
        lib.nameValuePair (pruneService name) {
          wantedBy = [ "timers.target" ];
          timerConfig = repository.cloud.pruneTimerConfig;
        }
      ) enabledOffloads;
  };
}
