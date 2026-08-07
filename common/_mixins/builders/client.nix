{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  buildersFor =
    use:
    builtins.concatMap (
      pool: hostInventory.builders.byUse.${use}.${pool} or [ ]
    ) config.host.build.pools;
  nixBuilders = builtins.filter (builder: builder.name != hostname) (buildersFor "nix-build");
  reviewBuilders = buildersFor "nixpkgs-review";
  identityFileFor =
    builder:
    let
      sshIdentity = hostInventory.ssh.identityForBuilderPool hostname builder.pool;
    in
    "${config.host.ssh.userDirectory}/${sshIdentity.fileName}";
  renderNixBuilder =
    builder:
    let
      identityFile = identityFileFor builder;
      hostPatterns = lib.concatStringsSep " " (
        lib.unique [
          builder.name
          builder.sshHost
        ]
      );
    in
    {
      machine = {
        hostName = builder.sshHost;
        inherit (builder)
          maxJobs
          speedFactor
          sshUser
          supportedFeatures
          systems
          ;
        protocol = "ssh-ng";
        sshKey = identityFile;
      };
      sshConfig = ''
        Host ${hostPatterns}
          Hostname ${builder.sshHost}
          IdentityFile ${identityFile}
          IdentitiesOnly yes
          User ${builder.sshUser}
      '';
    };
  renderReviewSshConfig = builder: ''
    Host ${builder.name}
      Hostname ${builder.sshHost}
      IdentityFile ${identityFileFor builder}
      User ${builder.sshUser}
  '';
  formatList = values: if values == [ ] then "-" else lib.concatStringsSep "," values;
  renderReviewBuilder =
    builder:
    "ssh://${builder.name} ${formatList builder.systems} - ${toString builder.maxJobs} "
    + "${toString builder.speedFactor} ${formatList builder.supportedFeatures} - -";
  renderedNixBuilders = map renderNixBuilder nixBuilders;
in
{
  config = lib.mkIf config.host.isOperatorSeat {
    nix.buildMachines = map (builder: builder.machine) renderedNixBuilders;
    programs.ssh = {
      knownHosts = builtins.listToAttrs (
        map (
          builder: lib.nameValuePair builder.sshHost { publicKey = builder.hostPublicKey; }
        ) reviewBuilders
      );
      extraConfig = lib.concatStringsSep "\n" (
        map (builder: builder.sshConfig) renderedNixBuilders ++ map renderReviewSshConfig reviewBuilders
      );
    };
    host.nixpkgsReview.extraBuilders = map renderReviewBuilder reviewBuilders;
  };
}
