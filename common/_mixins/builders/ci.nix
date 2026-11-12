{
  config,
  lib,
  sshKeys,
  ...
}:
let
  builder = config.host.nix.builder;
  enabled = builder != null && builtins.elem "ci" builder.uses;
  nixDaemon = lib.getExe' config.nix.package "nix-daemon";
  publicKey = sshKeys.keys.ciBuilder;
in
{
  config = lib.mkIf enabled {
    users.users.${config.host.username}.openssh.authorizedKeys.keys = [
      ''restrict,command="${nixDaemon} --stdio" ${publicKey}''
    ];
  };
}
