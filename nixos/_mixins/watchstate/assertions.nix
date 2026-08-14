{
  config,
  lib,
  watchstateModel,
  ...
}:
let
  inherit (watchstateModel) cfg jellyfin libraryPath;
  sso = config.host.sso.applications.watchstate;
  systemUser = sso.bootstrapOwner;
  systemAccount = config.host.sso.users.${systemUser};
in
{
  assertions = lib.optionals (cfg != null) [
    {
      assertion = jellyfin != null;
      message = "WatchState requires local Jellyfin.";
    }
    {
      assertion = libraryPath != null;
      message = "WatchState requires a Jellyfin media-library source.";
    }
    {
      assertion = builtins.elem sso.roles.admin systemAccount.groups;
      message = "The WatchState bootstrap owner must belong to its SSO admin group.";
    }
    {
      assertion = builtins.match "[a-z0-9_]+" systemUser != null;
      message = "The WatchState bootstrap owner must be a valid WatchState username.";
    }
  ];
}
