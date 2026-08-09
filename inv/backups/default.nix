{
  factLibraryName,
  inventory,
  inventoryLib,
  lib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix { publicKeys = inventory.public-keys; };
  enrich = import ./enrich.nix { inherit lib; };
  assertions = import ./asserts.nix { inherit lib; };
}
