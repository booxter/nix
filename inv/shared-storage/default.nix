{
  factLibraryName,
  inventory,
  inventoryLib,
  lib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix { mediaLibraries = inventory.media-libraries; };
  enrich = import ./enrich.nix {
    accounts = inventory.accounts;
    inherit lib;
  };
  assertions = import ./asserts.nix { inherit lib; };
}
