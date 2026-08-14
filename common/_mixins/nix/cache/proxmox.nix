{ lib }:
let
  readPublicKey = import ../../../_lib/read-public-key.nix { inherit lib; };
in
{
  substituter = "https://cache.saumon.network/proxmox-nixos";
  trustedPublicKeys = [ (readPublicKey ./public-keys/proxmox-nixos.pub) ];
}
