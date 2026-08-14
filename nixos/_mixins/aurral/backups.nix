{
  config,
  lib,
  ...
}:
let
  cfg = config.host.aurral;
in
{
  config = lib.mkIf (cfg != null) {
    host.backups.sources.aurral-database = {
      title = "Aurral";
      capture = {
        type = "sqlite";
        database = {
          path = "${cfg.stateDir}/aurral.db";
          destinationDir = "${cfg.stateDir}-backup/latest";
        };
      };
    };
  };
}
