{
  factLibraryName,
  inventoryLib,
  lib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix { inherit lib; };
}
