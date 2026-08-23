{ lib }:
let
  readPublicKey = import ../common/_lib/read-public-key.nix { inherit lib; };
in
{
  cache = {
    realm = "home";
    endpoint = "https://nix-cache.home.arpa";
    cacheName = "default";
    trustedPublicKey = readPublicKey ../nixos/cache/attic-signing.pub;
  };
}
