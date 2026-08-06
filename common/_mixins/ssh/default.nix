{
  config,
  hostInventory,
  lib,
  ...
}:
let
  username = config.host.username;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  hostKeyPath = name: ../../../public-keys/hosts + "/${name}.pub";
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
  managedKnownHosts = lib.mapAttrs (name: spec: {
    hostNames = hostInventory.toSshKnownHostNames spec;
    publicKey = readPublicKey (hostKeyPath name);
  }) hostInventory.hostSpecsByName;
in
{
  imports = [ ./ticket-server.nix ];

  services.openssh.enable = true;

  programs.ssh.knownHosts = managedKnownHosts // {
    frame-initrd = {
      hostNames = [ "frame-initrd" ];
      publicKey = readPublicKey ../../../public-keys/hosts/frame-initrd.pub;
    };
  };

  users.users.${username}.openssh.authorizedKeys.keys =
    if config.host.isWork then workKeys else personalKeys;
}
