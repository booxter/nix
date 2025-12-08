{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Where the repo lives locally on each machine
  repoDir = "/var/src/nix-config";

  # The remote and branch to track
  remoteUrl = "https://github.com/booxter/nix.git";
  remoteName = "origin";
  remoteBranch = "master";
in
{
  systemd.services.nixos-auto-upgrade = {
    description = "Auto upgrade NixOS from Git repo";
    wantedBy = [ ]; # started by timer, not directly

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Nice = 10;
    };

    path = [
      pkgs.git
      pkgs.gnumake
      pkgs.hostname-debian
      pkgs.nix
      pkgs.nixos-rebuild
      pkgs.sudo
      pkgs.bashInteractive
    ];

    script = ''
      set -euo pipefail

      if [ ! -d "${repoDir}/.git" ]; then
        echo "Cloning repo into ${repoDir}..."
        mkdir -p "${repoDir}"
        git clone "${remoteUrl}" "${repoDir}"
      fi

      cd "${repoDir}"

      old_rev="$(git rev-parse HEAD || echo none)"
      git fetch "${remoteName}" "${remoteBranch}"
      new_rev="$(git rev-parse "${remoteName}/${remoteBranch}")"

      if [ "$old_rev" = "$new_rev" ]; then
        echo "No new commits; nothing to do."
        exit 0
      fi

      echo "Updating from $old_rev to $new_rev"
      git reset --hard "$new_rev"

      host="$(hostname)"
      echo "Rebuilding $host from flake..."
      make nixos-switch
    '';
  };

  systemd.timers.nixos-auto-upgrade = {
    description = "Nightly NixOS auto-upgrade from Git";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Run on Sundays at night
      OnCalendar = "Sun 03:00";
      RandomizedDelaySec = "15min";
      Persistent = true; # catch up missed runs after downtime
    };
  };
}
