{
  factLibraryName,
  inventory,
  inventoryLib,
  lib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix;
  enrich = import ./enrich.nix {
    inherit lib;
    hosts = inventory.hosts;
  };
}
