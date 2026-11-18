{ backend, pkgs }:
let
  useYubikey = backend == "yubikey";
  useSecretive = backend == "secretive";
in
{
  inherit useYubikey useSecretive;
  openssh = if useYubikey then pkgs.openssh-yubikey else pkgs.openssh;
  ssh-ticket = if useYubikey then pkgs.ssh-ticket-yubikey else pkgs.ssh-ticket;
}
