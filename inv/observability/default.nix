{
  factLibraryName,
  inventoryLib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix;
}
