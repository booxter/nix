{
  lib,
  config,
  pkgs,
  username,
  hostname,
  ...
}:
{
  programs.ssh = {
    knownHosts = {
      "nvws" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHfcwsYERqU04xrr6LY0lcbkmlcFuThaURac/AlvP8mR";
      };
    };
    extraConfig =
      let
        identityFile = "${config.users.users.${username}.home}/.ssh/id_ed25519";
        user = "ihrachyshka";
      in
      ''
        Host nvws
          Hostname nvws
          IdentityFile ${identityFile}
          User ${user}
      '';
  };
  environment.systemPackages = [ pkgs.openssh_gssapi ];

  nix.buildMachines = lib.optional (hostname != "nvws") {
    hostName = "nvws";
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
