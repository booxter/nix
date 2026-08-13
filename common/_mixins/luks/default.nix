{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
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

  options.host.luks.remoteUnlock = {
    enable = lib.mkEnableOption "remote LUKS unlock through initrd SSH";

    publicKey = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Initrd SSH host public key published to operator seats.";
    };
  };

  config = lib.mkIf config.host.security.secrets.operator.enable {
    programs.ssh = {
      knownHosts = lib.mapAttrs (name: server: {
        hostNames = [ name ];
        inherit (server) publicKey;
      }) model.servers;
      extraConfig = lib.mkAfter sshConfig;
    };
  };
}
