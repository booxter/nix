{ isWork, lib, ... }:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
in
{
  imports = lib.optionals (!isWork) [ ./ticket-server.nix ];

  services.openssh.enable = true;

  programs.ssh.knownHosts = {
    "beast" = {
      publicKey = readPublicKey ../../../public-keys/hosts/beast.pub;
    };
  };
}
