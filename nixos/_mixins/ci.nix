{
  config,
  lib,
  pkgs,
  ...
}:
let
  runnerCount = config.host.ci.runners;
  runnerNames = map (index: "${config.networking.hostName}-${toString index}") (
    lib.range 1 runnerCount
  );
in
{
  options.host.ci.runners = lib.mkOption {
    type = lib.types.ints.unsigned;
    default = 0;
    description = "Number of ephemeral runners for the fleet repository.";
  };

  config = lib.mkIf (runnerCount > 0) {
    services.github-runners = lib.genAttrs runnerNames (name: {
      enable = true;
      url = "https://github.com/booxter/nix";
      tokenFile = config.sops.secrets."github/actions_runner/token".path;
      tokenType = "access";
      inherit name;
      ephemeral = true;
      extraLabels = [ "nix-ci" ];
      noDefaultLabels = true;
      replace = true;
      extraEnvironment.NIX_CACHE_HOME = "/var/cache/github-runner/${name}/nix";
      serviceOverrides = {
        # Registration wipes the state and work directories, so keep Nix's
        # fetch and evaluation caches in a separate directory for each runner.
        CacheDirectory = "github-runner/${name}";
        CacheDirectoryMode = "0700";

        # Ephemeral runners must register again after job completion or an OOM kill.
        Restart = lib.mkForce "always";
        RestartSec = "5s";
      };
      extraPackages = with pkgs; [
        findutils
        gawk
        gnumake
        gnugrep
        jq
      ];
    });

    sops.secrets."github/actions_runner/token" = { };
  };
}
