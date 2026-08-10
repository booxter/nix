{
  config,
  lib,
  ...
}:
let
  cfg = config.host.nix.nixpkgs-review;
  username = config.host.username;
in
{
  options.host.nix.nixpkgs-review.cacheDir = lib.mkOption {
    type = with lib.types; nullOr nonEmptyStr;
    default = if config.host.realm == "work" then "/nix/var/nixpkgs-review" else null;
    defaultText = lib.literalExpression ''
      if config.host.realm == "work" then "/nix/var/nixpkgs-review" else null
    '';
    description = "Directory where nixpkgs-review keeps its checkouts and worktrees.";
  };

  config = lib.mkIf (cfg.cacheDir != null) {
    assertions = [
      {
        assertion = lib.hasPrefix "/nix/" cfg.cacheDir;
        message = "host.nix.nixpkgs-review.cacheDir must be below /nix";
      }
    ];

    home-manager.users.${username}.home.sessionVariables.NIXPKGS_REVIEW_CACHE_DIR = cfg.cacheDir;

    system.activationScripts.preActivation.text = lib.mkAfter ''
      if [ -L ${lib.escapeShellArg cfg.cacheDir} ]; then
        echo "${cfg.cacheDir} must be a real directory, not a symlink" >&2
        exit 1
      fi

      /usr/bin/install -d -m 0700 -o ${lib.escapeShellArg username} -g staff ${lib.escapeShellArg cfg.cacheDir}
    '';
  };
}
