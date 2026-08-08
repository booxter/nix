{
  config,
  lib,
  ...
}:
let
  cfg = config.services.audiobookshelf;
in
{
  options.services.audiobookshelf.apiToken = {
    sopsKey = lib.mkOption {
      type = lib.types.str;
      default = "audiobookshelf/bootstrap/api_token";
      internal = true;
      description = "SOPS key containing the Audiobookshelf bootstrap API token.";
    };

    file = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
      description = "File containing the Audiobookshelf bootstrap API token.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.audiobookshelf.apiToken.file = config.sops.secrets.${cfg.apiToken.sopsKey}.path;

    sops.secrets.${cfg.apiToken.sopsKey} = {
      mode = "0400";
      restartUnits =
        lib.optional cfg.nativeBackup.enable "audiobookshelf-backup-bootstrap.service"
        ++ lib.optional cfg.oidc.enable "audiobookshelf-oidc-bootstrap.service";
    };
  };
}
