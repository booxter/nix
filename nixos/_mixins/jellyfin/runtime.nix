{
  config,
  lib,
  ...
}:
let
  cfg = config.services.jellyfin;
in
{
  options.services.jellyfin.supplementaryGroups = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Supplementary groups granted to the Jellyfin service user.";
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user}.extraGroups = cfg.supplementaryGroups;
  };
}
