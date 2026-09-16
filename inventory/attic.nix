{ lib }:
let
  readPublicKey = import ../common/_lib/read-public-key.nix { inherit lib; };
in
{
  beast = {
    realm = "home";
    endpoint = "https://attic.home.arpa";
    defaultCache = "default";
    caches.default.trustedPublicKey = readPublicKey ../nixos/beast/attic-signing.pub;
    caches.github = {
      endpoint = "https://cache.ihar.dev";
      public = true;
      trustedPublicKey = readPublicKey ../nixos/beast/attic-github-signing.pub;
    };
  };
}
