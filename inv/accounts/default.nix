{
  factLibraryName,
  inventoryLib,
  lib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix;
  assertions = import ./asserts.nix { inherit lib; };
}
