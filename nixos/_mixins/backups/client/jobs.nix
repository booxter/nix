{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    destination
    excludesFor
    hostName
    jobName
    jobNameFor
    minimalPathsFor
    passwordSecretFor
    sourceEntries
    sources
    sshKeySecret
    ;
in
{
  config = lib.mkIf (sources != { } && destination != null) {
    host.backups.jobs = lib.mkMerge (
      [
        {
          ${jobName} = {
            title =
              if destination.transport == "local" then
                "${lib.strings.toSentenceCase hostName} Local Restic"
              else
                "Restic To ${lib.strings.toSentenceCase destination.server}";
            user = destination.user;
            timerConfig = {
              OnCalendar = "04:45";
              RandomizedDelaySec = "5m";
              Persistent = true;
            };
            retention = {
              daily = 7;
              weekly = 8;
              monthly = 6;
            };
            paths = minimalPathsFor sourceEntries;
            exclude = excludesFor sourceEntries;
            repository = {
              type = destination.transport;
              path = destination.repositoryPath;
              passwordFile = config.sops.secrets.${passwordSecretFor destination}.path;
              dependencyUnits = [ "sops-install-secrets.service" ];
              sftp = lib.optionalAttrs (destination.transport == "sftp") {
                host = destination.server;
                user = destination.ingestUser;
                identityFile = config.sops.secrets.${sshKeySecret}.path;
              };
            };
          };
        }
      ]
      ++ map (
        source:
        let
          jobName = jobNameFor source;
          unitName = source.capture.unit.service;
        in
        {
          ${jobName} = {
            preparations = lib.optionalAttrs (source.capture.type == "unit") {
              ${unitName} = {
                service = unitName;
                title = "${source.title} Capture";
                # Source output paths are aggregated into the job above. Keep
                # the preparation concerned only with service ordering.
                paths = [ ];
              };
            };
          };
        }
      ) sourceEntries
    );
  };
}
