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
  config = lib.mkMerge [
    {
      nix.gc.interval = [
        {
          Hour = 3;
          Minute = 15;
        }
      ];
      nix.optimise.interval = [
        {
          Hour = 4;
          Minute = 15;
        }
      ];

      system.activationScripts.postActivation.text = lib.mkAfter ''
        if [ -d /nix/store ]; then
          echo "Hiding the Nix store from macOS metadata services."
          /usr/bin/chflags hidden /nix

          if [ ! -e /nix/.metadata_never_index ]; then
            /usr/bin/install -m 0644 -o root -g wheel /dev/null /nix/.metadata_never_index
          fi

          /usr/bin/install -d -m 0700 -o root -g wheel /nix/.fseventsd
          if [ ! -e /nix/.fseventsd/no_log ]; then
            /usr/bin/install -m 0600 -o root -g wheel /dev/null /nix/.fseventsd/no_log
          fi
        fi
      '';
    }
    (lib.mkIf config.host.isWork {
      # Keep nixpkgs-review's worktrees in a dedicated real directory under
      # /nix/var.
      home-manager.users.${username}.home.sessionVariables.NIXPKGS_REVIEW_CACHE_DIR = reviewCacheDir;

      system.activationScripts.preActivation.text = lib.mkAfter ''
        if [ -L ${lib.escapeShellArg reviewCacheDir} ]; then
          echo "${reviewCacheDir} must be a real directory, not a symlink" >&2
          exit 1
        fi

        /usr/bin/install -d -m 0700 -o ${lib.escapeShellArg username} -g staff ${lib.escapeShellArg reviewCacheDir}
      '';
    })
  ];
}
