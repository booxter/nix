{ lib }:
let
  readPublicKey = import ../common/_lib/read-public-key.nix { inherit lib; };
in
{
  beast = {
    realm = "home";
    endpoint = "https://attic.home.arpa";
    cacheName = "default";
    trustedPublicKey = readPublicKey ../nixos/beast/attic-signing.pub;
  };
}
