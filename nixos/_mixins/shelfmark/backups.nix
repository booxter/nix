{ config, lib, ... }:
let
  cfg = config.host.shelfmark;
in
{
  config = lib.mkIf (cfg != null && cfg.backups.enable) {
    host.backups.sources.shelfmark = {
      title = "Shelfmark";
      paths = [ "${cfg.stateDir}/plugins" ];
      capture = {
        type = "sqlite";
        database = {
          path = "${cfg.stateDir}/users.db";
          destinationDir = "${cfg.stateDir}-backup/latest";
          extraCopies = [
            {
              source = "${cfg.stateDir}/.flask_secret";
              mode = "0600";
              optional = false;
            }
            {
              source = "${cfg.stateDir}/settings.json";
              optional = false;
            }
          ];
        };
      };
    };
  };
}
