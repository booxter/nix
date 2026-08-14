{
  config,
  ...
}:
let
  cfg = config.host.watchstate;
  sso = config.host.sso.applications.watchstate;
  systemUser = sso.bootstrapOwner;
  systemAccount = config.host.sso.users.${systemUser};
in
{
  assertions = [
    {
      assertion = !cfg.enable || config.host.jellyfin != null;
      message = "WatchState requires local Jellyfin.";
    }
    {
      assertion = !cfg.enable || cfg.library.source != null;
      message = "WatchState requires a Jellyfin media-library source.";
    }
    {
      assertion = !cfg.enable || !cfg.backups.enable || cfg.backups.stagingDirectory != null;
      message = "host.watchstate.backups.stagingDirectory must be set when WatchState backups are enabled.";
    }
    {
      assertion = !cfg.enable || builtins.elem sso.roles.admin systemAccount.groups;
      message = "The WatchState bootstrap owner must belong to its SSO admin group.";
    }
    {
      assertion = !cfg.enable || builtins.match "[a-z0-9_]+" systemUser != null;
      message = "The WatchState bootstrap owner must be a valid WatchState username.";
    }
  ];
}
