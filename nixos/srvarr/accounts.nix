{ hostAccounts }:
{
  gids = {
    prowlarr = 287;
  };

  uids = builtins.mapAttrs (_: account: account.uid) hostAccounts.users // {
    bazarr = 232;
    prowlarr = 293;
    radarr = 275;
    sonarr = 274;
  };
}
