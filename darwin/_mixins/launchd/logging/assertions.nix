{
  jobsByDomain,
  launchdLib,
  lib,
  logLocations,
  managedHomeManagerUserAgents,
  homeManagerUsername,
}:
let
  locationValues = builtins.attrValues logLocations;
  locationFor =
    scope: path:
    lib.findFirst (
      location: location.scope == scope && location.directory == builtins.dirOf path
    ) null locationValues;
  assertionsFor =
    {
      jobs,
      optionPath,
      scope ? null,
      serviceConfigName,
      serviceConfigFor,
    }:
    let
      loggingAssertions = lib.mapAttrsToList (
        name: job:
        let
          serviceConfig = serviceConfigFor job;
          stdout = serviceConfig.StandardOutPath;
          stderr = serviceConfig.StandardErrorPath;
        in
        {
          assertion = stdout != null && stderr != null;
          message = "${optionPath}.${name} must define both StandardOutPath and StandardErrorPath";
        }
      ) jobs;
      pathAssertions = lib.concatMap (
        name:
        let
          serviceConfig = serviceConfigFor jobs.${name};
        in
        map
          (field: {
            assertion = serviceConfig.${field} == null || lib.hasPrefix "/" serviceConfig.${field};
            message = "${optionPath}.${name}.${serviceConfigName}.${field} must be an absolute path";
          })
          [
            "StandardOutPath"
            "StandardErrorPath"
          ]
      ) (builtins.attrNames jobs);
      destinationAssertions = lib.optionals (scope != null) (
        lib.concatMap (
          name:
          let
            serviceConfig = serviceConfigFor jobs.${name};
            paths = [
              serviceConfig.StandardOutPath
              serviceConfig.StandardErrorPath
            ];
            locationForPath = path: if path == null then null else locationFor scope path;
            stdoutLocation = locationForPath serviceConfig.StandardOutPath;
            stderrLocation = locationForPath serviceConfig.StandardErrorPath;
          in
          lib.concatMap (
            path:
            lib.optionals (path != null) [
              {
                assertion = lib.hasSuffix ".log" path;
                message = "${optionPath}.${name} log path must end in .log: ${path}";
              }
              {
                assertion = locationForPath path != null;
                message = "${optionPath}.${name} log path is not in a registered ${scope} log directory: ${path}";
              }
            ]
          ) paths
          ++ [
            {
              assertion =
                stdoutLocation == null
                || stderrLocation == null
                || stdoutLocation.collect == stderrLocation.collect;
              message = "${optionPath}.${name} must not split stdout and stderr between collected and private logs";
            }
          ]
        ) (builtins.attrNames jobs)
      );
    in
    loggingAssertions ++ pathAssertions ++ destinationAssertions;
  locationDirectories = map (location: location.directory) locationValues;
in
[
  {
    assertion = builtins.all (directory: lib.hasPrefix "/" directory) locationDirectories;
    message = "Launchd log location directories must be absolute paths";
  }
  {
    assertion = builtins.length locationDirectories == builtins.length (lib.unique locationDirectories);
    message = "Launchd log location directories must be unique";
  }
]
++ lib.concatLists (
  lib.mapAttrsToList (
    domain: jobs:
    assertionsFor {
      jobs = launchdLib.managedJobs jobs;
      optionPath = launchdLib.optionPaths.${domain};
      scope = "system";
      serviceConfigName = "serviceConfig";
      serviceConfigFor = job: job.serviceConfig;
    }
  ) jobsByDomain
)
++ assertionsFor {
  jobs = managedHomeManagerUserAgents;
  optionPath = "home-manager.users.${homeManagerUsername}.launchd.agents";
  serviceConfigName = "config";
  serviceConfigFor = job: job.config;
}
