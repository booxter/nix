{ sharedAccounts }:
{
  gids = {
    prowlarr = 287;
    seerr = 250;
  };

  uids = builtins.mapAttrs (_: account: account.uid) sharedAccounts.users // {
    audiobookshelf = 156;
    bazarr = 232;
    prowlarr = 293;
    radarr = 275;
    seerr = 262;
    shelfmark = 250;
    sonarr = 274;
  };
}
