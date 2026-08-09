{
  config,
  ...
}:
let
  stateRoot = config.host.srvarrPaths.stateDir;
  mysqlDataDir = "${stateRoot}/mysql";
  pinepodsDatabaseDir = "${stateRoot}/pinepods/postgresql";
  backupExclude = [
    "${stateRoot}/*/logs"
    "${stateRoot}/*/logs/**"
    "${stateRoot}/*/cache"
    "${stateRoot}/*/cache/**"
    mysqlDataDir
    "${mysqlDataDir}/**"
    pinepodsDatabaseDir
    "${pinepodsDatabaseDir}/**"
  ];
in
{
  host.backups.sources = {
    srvarr-state = {
      title = "Servarr State";
      paths = [ stateRoot ];
      exclude = backupExclude;
    };
  };

  # PinePods' downloaded podcast media lives under the separate media root and
  # is intentionally outside this state-only backup.
}
