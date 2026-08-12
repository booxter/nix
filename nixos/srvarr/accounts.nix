{ hostAccounts }:
{
  gids = {
    prowlarr = 287;
    seerr = 250;
  };

  uids = builtins.mapAttrs (_: account: account.uid) hostAccounts.users // {
    audiobookshelf = 156;
    bazarr = 232;
    prowlarr = 293;
    radarr = 275;
    seerr = 262;
    sonarr = 274;
  };
}
