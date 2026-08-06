{ config, lib, ... }:
let
  username = config.host.username;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  workKeys = [
    (readPublicKey ../../../public-keys/users/jgwxhwdl4x.pub)
    (readPublicKey ../../../public-keys/users/jgwxhwdl4x-nix-builder.pub)
  ];
  personalKeys = [
    (readPublicKey ../../../public-keys/users/mmini.pub)
    (readPublicKey ../../../public-keys/users/mair.pub)
    (readPublicKey ../../../public-keys/users/frame.pub)
    (readPublicKey ../../../public-keys/yubikey.pub)
    (readPublicKey ../../../public-keys/mair-secretive.pub)
  ];
in
{
  imports = [
    ./known-hosts.nix
    ./ticket-server.nix
  ];

  services.openssh.enable = true;

  users.users.${username}.openssh.authorizedKeys.keys =
    if config.host.isWork then workKeys else personalKeys;
}
