{
  config,
  isDarwin,
  isWork,
  lib,
  username,
  ...
}:
let
  cacheDir = "/nix/var/nixpkgs-review";
in
{
  options.host.nixpkgsReview.builders = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    internal = true;
    description = "Nix builders made available to nixpkgs-review on this host.";
  };

  config = {
    host.nixpkgsReview.builders =
      let
        configuredBuilders =
          if config.nix.buildMachines == [ ] then "" else config.environment.etc."nix/machines".text;
      in
      lib.filter (builder: builder != "") (lib.splitString "\n" configuredBuilders);
  }
  // lib.optionalAttrs (isDarwin && isWork) {
    # Keep nixpkgs-review's worktrees in a dedicated real directory under
    # /nix/var.
    home-manager.users.${username}.home.sessionVariables.NIXPKGS_REVIEW_CACHE_DIR = cacheDir;

    system.activationScripts.preActivation.text = lib.mkAfter ''
      if [ -L ${lib.escapeShellArg cacheDir} ]; then
        echo "${cacheDir} must be a real directory, not a symlink" >&2
        exit 1
      fi

      /usr/bin/install -d -m 0700 -o ${lib.escapeShellArg username} -g staff ${lib.escapeShellArg cacheDir}
    '';
  };
}
