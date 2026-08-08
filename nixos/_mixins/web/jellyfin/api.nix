{
  config,
  lib,
  ...
}:
let
  cfg = config.services.jellyfin;
in
{
  options.services.jellyfin.apiKey = {
    sopsKey = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin/apiKey";
      internal = true;
      description = "SOPS key containing the Jellyfin API key used by local integrations.";
    };

    file = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      internal = true;
      description = "File containing the Jellyfin API key used by local integrations.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.jellyfin.apiKey.file = config.sops.secrets.${cfg.apiKey.sopsKey}.path;

    sops.secrets.${cfg.apiKey.sopsKey} = {
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };
}
