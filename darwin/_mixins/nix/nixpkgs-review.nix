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

  system.activationScripts.preActivation.text = lib.mkAfter ''
    if [ -L ${lib.escapeShellArg cacheDir} ]; then
      echo "${cacheDir} must be a real directory, not a symlink" >&2
      exit 1
    fi

    /usr/bin/install -d -m 0700 -o ${lib.escapeShellArg username} -g staff ${lib.escapeShellArg cacheDir}
  '';
}
