{
  lib,
  config,
  username,
  hostname,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
in
{
  programs.ssh = {
    knownHosts = {
      "nvws.local" = {
        publicKey = readPublicKey ../../../public-keys/hosts/nvws-local.pub;
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
          IdentitiesOnly yes
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
