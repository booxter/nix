{
  config,
  fleetInventory,
  lib,
}:
let
  username = config.host.username;
  identityFileName = config.host.nix.builderClient.sshIdentityFileName;
  identityFile = "${config.users.users.${username}.home}/.ssh/${identityFileName}";
  toBuilder = _name: builder: {
    inherit (builder)
      hostName
      maxJobs
      realm
      speedFactor
      supportedFeatures
      uses
      ;
    protocol = "ssh-ng";
    sshKey = identityFile;
    sshUser = username;
    systems = [ builder.system ];
  };
  candidates = lib.mapAttrs toBuilder (
    removeAttrs fleetInventory.builders [ config.networking.hostName ]
  );
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
