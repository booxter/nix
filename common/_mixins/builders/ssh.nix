{ config, lib, ... }:
let
  builders = config.host.nix.builder-pool;
  externalBuilders = config.host.nix.external-builders;
  toKnownHost = _: builder: lib.nameValuePair builder.hostName { inherit (builder) publicKey; };
  toSshConfig = name: builder: ''
    Host ${name}
      Hostname ${builder.hostName}
      IdentityFile ${builder.sshKey}
      IdentitiesOnly yes
      User ${builder.sshUser}
  '';
in
{
  config = lib.mkIf (config.host.nix.builderClient != null) {
    programs.ssh = {
      knownHosts = lib.mapAttrs' toKnownHost externalBuilders;
      extraConfig = lib.concatStringsSep "\n" (lib.mapAttrsToList toSshConfig builders);
    };
  };
}
