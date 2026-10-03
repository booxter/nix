{
  config,
  lib,
  pkgs,
  ...
}:
let
  runnerNames = map (index: "ci-${toString index}") (lib.range 1 6);
in
{
  system.stateVersion = "25.11";

  host = {
    network.macAddress = "bc:24:11:7f:01:17";
    nix.builderClient = {
      buildUse = "ci";
      sshIdentityFile = config.sops.secrets."nix/builder_private_key".path;
    };
    proxmox.guest = {
      cores = 12;
      memoryGiB = 32;
      balloonGiB = 24;
      diskGiB = 300;
    };
  };

  nix.settings.max-jobs = lib.mkForce 0;

  services.github-runners = lib.genAttrs runnerNames (name: {
    enable = true;
    url = "https://github.com/booxter/nix";
    tokenFile = config.sops.secrets."github/actions_runner/token".path;
    inherit name;
    ephemeral = true;
    extraLabels = [ "nix-ci" ];
    noDefaultLabels = true;
    replace = true;
    extraPackages = with pkgs; [
      attic-client
      findutils
      gawk
      gnumake
      gnugrep
      jq
    ];
  });

  sops.secrets = {
    "github/actions_runner/token" = { };
    "nix/builder_private_key" = {
      mode = "0400";
      owner = "root";
    };
  };
}
