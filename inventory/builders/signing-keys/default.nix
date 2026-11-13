{ lib }:
let
  readPublicKey = import ../../../common/_lib/read-public-key.nix { inherit lib; };
in
lib.mapAttrs (_: readPublicKey) {
  builder1 = ./builder1.pub;
  builder2 = ./builder2.pub;
  builder3 = ./builder3.pub;
  ci = ./ci.pub;
  frame = ./frame.pub;
  mair = ./mair.pub;
  mmini = ./mmini.pub;
}
