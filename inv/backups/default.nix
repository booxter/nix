{
  factLibraryName,
  inventoryLib,
  lib,
  readPublicKey,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix { inherit readPublicKey; };
  enrich = import ./enrich.nix { inherit lib; };
  assertions = import ./asserts.nix { inherit lib; };
}
