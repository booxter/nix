{
  config,
  lib,
  outputs,
}:
let
  username = config.host.username;
  identityFileName = config.host.nix.builderClient.sshIdentityFileName;
  identityFile = "${config.users.users.${username}.home}/.ssh/${identityFileName}";
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  otherConfigurations = removeAttrs configurations [ config.networking.hostName ];
  toBuilder =
    _name: configuration:
    let
      host = configuration.config.host;
      builder = host.nix.builder;
    in
    {
      inherit (host) realm;
      inherit (builder)
        hostName
        maxJobs
        speedFactor
        supportedFeatures
        uses
        ;
      protocol = "ssh-ng";
      sshKey = identityFile;
      sshUser = username;
      systems = [ configuration.config.nixpkgs.hostPlatform.system ];
    };
  providers = lib.filterAttrs (
    _: configuration: configuration.config.host.nix.builder != null
  ) otherConfigurations;
  candidates = lib.mapAttrs toBuilder providers;
  realmBuilders = lib.filterAttrs (_: builder: builder.realm == config.host.realm) candidates;
  fleetBuilders = lib.mapAttrs (_: builder: removeAttrs builder [ "realm" ]) realmBuilders;
  externalBuilders = lib.mapAttrs (
    _: builder: removeAttrs builder [ "publicKey" ]
  ) config.host.nix.external-builders;
  collisions = lib.intersectLists (builtins.attrNames fleetBuilders) (
    builtins.attrNames externalBuilders
  );
  builderPool =
    assert lib.assertMsg (collisions == [ ]) (
      "external Nix builders collide with fleet builders: ${lib.concatStringsSep ", " collisions}"
    );
    fleetBuilders // externalBuilders;
in
{
  inherit builderPool;
}
