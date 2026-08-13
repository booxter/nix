{
  config,
  hostSpec,
  lib,
  outputs,
}:
let
  username = config.host.username;
  identityFileName = config.host.nix.builder.sshIdentityFileName;
  identityFile = "${config.users.users.${username}.home}/.ssh/${identityFileName}";
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  otherConfigurations = builtins.removeAttrs configurations [ hostSpec.name ];
  toBuilder =
    _name: configuration:
    let
      host = configuration.config.host;
    in
    {
      inherit (host) realm;
      inherit (host.nix.builder)
        enable
        hostName
        maxJobs
        speedFactor
        supportedFeatures
        uses
        ;
      source = "fleet";
      publicKey = null;
      protocol = "ssh-ng";
      sshKey = identityFile;
      sshUser = username;
      systems = [ host.platform ];
    };
  candidates = lib.mapAttrs toBuilder otherConfigurations;
  realmBuilders = lib.filterAttrs (
    _: builder: builder.enable && builder.realm == config.host.realm
  ) candidates;
  fleetBuilders = lib.mapAttrs (
    _: builder:
    removeAttrs builder [
      "enable"
      "realm"
    ]
  ) realmBuilders;
  externalBuilders = config.host.nix.external-builders;
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
