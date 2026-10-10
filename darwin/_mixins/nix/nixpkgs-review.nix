{
  config,
  lib,
  ...
}:
let
  cacheDir = "/nix/var/nixpkgs-review";
  username = config.host.username;
in
lib.mkIf (config.host.realm == "work") {
  home-manager.users.${username}.home.sessionVariables.NIXPKGS_REVIEW_CACHE_DIR = cacheDir;

  system.tmpfiles.settings.nixpkgs-review.${cacheDir}.d = {
    mode = "0700";
    user = username;
    group = "staff";
  };
}
