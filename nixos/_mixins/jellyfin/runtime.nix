{
  config,
  lib,
  ...
}:
let
  cfg = config.services.jellyfin;
in
{
  options.services.jellyfin = {
    localPort = lib.mkOption {
      type = lib.types.port;
      default = 8096;
      description = "Loopback HTTP port expected by local Jellyfin integrations.";
    };

    localUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString cfg.localPort}";
      readOnly = true;
      internal = true;
      description = "Loopback HTTP URL used by local Jellyfin integrations.";
    };

    supplementaryGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Supplementary groups granted to the Jellyfin service user.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user}.extraGroups = cfg.supplementaryGroups;
  };
}
