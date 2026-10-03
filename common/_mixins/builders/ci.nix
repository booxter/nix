{
  config,
  lib,
  ...
}:
let
  readPublicKey = import ../../_lib/read-public-key.nix { inherit lib; };
  builder = config.host.nix.builder;
  enabled = builder != null && builtins.elem "ci" builder.uses;
  nixDaemon = lib.getExe' config.nix.package "nix-daemon";
  publicKey = readPublicKey ../ssh/public-keys/nix-ci-builder.pub;
in
{
  config = lib.mkIf enabled {
    users.users.${config.host.username}.openssh.authorizedKeys.keys = [
      ''restrict,command="${nixDaemon} --stdio" ${publicKey}''
    ];
  };
}
