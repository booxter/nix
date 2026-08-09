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
    accounts = inventory.accounts;
    sharedStorage = inventory.shared-storage;
    inherit lib;
  };
  assertions = import ./asserts.nix {
    inherit lib;
    sharedStorage = inventory.shared-storage;
  };
}
