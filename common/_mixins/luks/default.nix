{
  config,
  facts,
  hostSpec,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      facts
      hostSpec
      lib
      outputs
      ;
  };
  sshConfig = lib.concatMapStringsSep "\n" (name: ''
    Host ${name}
      HostName ${model.servers.${name}.hostName}
      HostKeyAlias ${name}
      User root
      RequestTTY force
  '') (builtins.attrNames model.servers);
in
{
  imports = [ ./assertions.nix ];

  options.host.luks.remoteUnlock.enable = lib.mkEnableOption "remote LUKS unlock through initrd SSH";

  config = lib.mkIf config.host.isOperatorSeat {
    programs.ssh = {
      knownHosts = lib.mapAttrs (name: server: {
        hostNames = [ name ];
        inherit (server) publicKey;
      }) model.servers;
      extraConfig = lib.mkAfter sshConfig;
    };
  };
}
