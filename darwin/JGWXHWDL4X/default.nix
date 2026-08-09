{
  config,
  lib,
  ...
}:
let
  username = config.host.username;
  reviewCacheDir = "/nix/var/nixpkgs-review";
in
{
  system.stateVersion = 5;

  host.codex.mcp.maas.enable = true;

  host.fleetCacheWarmer = {
    enable = true;
    targetRealm = "work";
    pushToAttic = false;
  };

  # Keep nixpkgs-review's worktrees in a dedicated real directory under
  # /nix/var on this managed workstation.
  home-manager.users.${username}.home = {
    sessionVariables.NIXPKGS_REVIEW_CACHE_DIR = reviewCacheDir;
  };

  system.activationScripts.preActivation.text = lib.mkAfter ''
    if [ -L ${lib.escapeShellArg reviewCacheDir} ]; then
      echo "${reviewCacheDir} must be a real directory, not a symlink" >&2
      exit 1
    fi

    /usr/bin/install -d -m 0700 -o ${lib.escapeShellArg username} -g staff ${lib.escapeShellArg reviewCacheDir}
  '';
}
