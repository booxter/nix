{
  inventoryLib,
  lib,
  readPublicKey,
}:
inventoryLib.finalize {
  facts = import ./facts.nix { inherit readPublicKey; };
  enrich = import ./enrich.nix { inherit lib; };
  assertions = import ./asserts.nix { inherit lib; };
}
