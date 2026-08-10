{ config, lib, ... }:
let
  builders = config.host.nix.builder-pool;
  knownBuilders = lib.filterAttrs (_: builder: builder.publicKey != null) builders;
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
  config = lib.mkIf (config.host.isOperatorSeat && builders != { }) {
    programs.ssh = {
      knownHosts = lib.mapAttrs' toKnownHost knownBuilders;
      extraConfig = lib.concatStringsSep "\n" (lib.mapAttrsToList toSshConfig builders);
    };
  };
}
