{ hostInventory }:
let
  wgHome = hostInventory.site.wireguard.home;
in
map (name: {
  inherit name;
  inherit (wgHome.peers.${name}) address publicKey;
}) (builtins.attrNames wgHome.peers)
