{
  context,
  factLibraryName,
  inventory,
  inventoryLib,
  lib,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix {
    inherit lib;
    inherit (context) frame lanDomain;
  };
  enrich = import ./enrich.nix {
    inherit lib;
    realms = inventory.realms;
    inherit (context) lanDomain;
  };
  assertions = import ./asserts.nix { inherit lib; };
}
