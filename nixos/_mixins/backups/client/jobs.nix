{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model)
    activeDestinations
    excludesFor
    hostName
    jobNameFor
    jobNameForDestination
    minimalPathsFor
    passwordSecretFor
    sourceEntries
    sources
    sourcesByDestination
    sshKeySecretFor
    ;
in
{
  config = lib.mkIf (sources != { }) {
    host.backups.jobs = lib.mkMerge (
      lib.mapAttrsToList (
        name: destination:
        let
          jobName = jobNameForDestination name destination;
          destinationSources = sourcesByDestination.${name};
        in
        {
          ${jobName} = {
            title =
              if destination.transport == "local" then
                "${lib.strings.toSentenceCase hostName} Local Restic"
              else
                "Restic To ${lib.strings.toSentenceCase destination.server}";
            inherit (destination)
              check
              retention
              timerConfig
              user
              ;
            paths = minimalPathsFor destinationSources;
            exclude = excludesFor destinationSources;
            repository = {
              type = destination.transport;
              path = destination.repositoryPath;
              passwordFile = config.sops.secrets.${passwordSecretFor name destination}.path;
              dependencyUnits = [ "sops-install-secrets.service" ];
              sftp = lib.optionalAttrs (destination.transport == "sftp") {
                host = destination.server;
                user = destination.ingestUser;
                identityFile = config.sops.secrets.${sshKeySecretFor name}.path;
              };
            };
          };
        }
      ) activeDestinations
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
