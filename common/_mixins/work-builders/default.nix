{
  lib,
  config,
  username,
  hostname,
  ...
}:
{
  programs.ssh = {
    knownHosts = {
      "nvws.local" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfcwsYERqU04xrr6LY0lcbkmlcFuThaURac/AlvP8mR";
      };
    };
    extraConfig =
      let
        identityFile = "${config.users.users.${username}.home}/.ssh/id_ed25519";
        user = "ihrachyshka";
      in
      ''
        Host nvws.local
          Hostname nvws.local
          IdentityFile ${identityFile}
          User ${user}
      '';
  };

  nix.buildMachines = lib.optional (hostname != "nvws") {
    hostName = "nvws.local";
    system = "x86_64-linux";
    protocol = "ssh-ng";
    maxJobs = 4;
    speedFactor = 100;
    supportedFeatures = [
      "nixos-test"
      "benchmark"
      "big-parallel"
      "kvm"
    ];
  };

  nix.settings.builders-use-substitutes = true;
  nix.distributedBuilds = true;
}
