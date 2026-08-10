{
  config,
  facts,
  lib,
  ...
}:
let
  username = config.host.username;
  identityFile = "${config.users.users.${username}.home}/.ssh/nix-community-builders";
  sshUser = "booxter";
  linuxFeatures = [
    "benchmark"
    "big-parallel"
    "kvm"
    "nixos-test"
  ];
  communityBuilders = {
    darwin-builder = {
      hostName = "darwin-build-box.nix-community.org";
      publicKey = facts.public-keys.hosts.nix-community-darwin-build-box;
      systems = [ "aarch64-darwin" ];
      maxJobs = 2;
      speedFactor = 20;
      supportedFeatures = [ "big-parallel" ];
    };
    remote-linux-builder = {
      hostName = "aarch64-build-box.nix-community.org";
      publicKey = facts.public-keys.hosts.nix-community-aarch64-build-box;
      systems = [ "aarch64-linux" ];
      maxJobs = 10;
      speedFactor = 20;
      supportedFeatures = linuxFeatures;
    };
    remote-linux-x86-builder = {
      hostName = "build-box.nix-community.org";
      publicKey = facts.public-keys.hosts.nix-community-build-box;
      systems = [ "x86_64-linux" ];
      maxJobs = 5;
      speedFactor = 20;
      supportedFeatures = linuxFeatures;
    };
  };
  formatList = values: if values == [ ] then "-" else lib.concatStringsSep "," values;
  toKnownHost = _: builder: lib.nameValuePair builder.hostName { inherit (builder) publicKey; };
  toSshConfig = name: builder: ''
    Host ${name}
      Hostname ${builder.hostName}
      IdentityFile ${identityFile}
      User ${sshUser}
  '';
  toReviewBuilder =
    name: builder:
    "ssh://${name} ${formatList builder.systems} - ${toString builder.maxJobs} "
    + "${toString builder.speedFactor} ${formatList builder.supportedFeatures} - -";
  enabled = builtins.elem "community" config.host.build.pools && config.host.isOperatorSeat;
in
{
  config = lib.mkIf enabled {
    programs.ssh = {
      knownHosts = lib.mapAttrs' toKnownHost communityBuilders;
      extraConfig = lib.concatStringsSep "\n" (lib.mapAttrsToList toSshConfig communityBuilders);
    };
    host.nixpkgsReview.extraBuilders = lib.mapAttrsToList toReviewBuilder communityBuilders;
  };
}
