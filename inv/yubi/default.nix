{
  context,
  factLibraryName,
  inventoryLib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix {
    inherit (context) frame mmini;
  };
}
