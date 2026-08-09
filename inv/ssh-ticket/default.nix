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
    inherit (context) frame mmini;
    publicKeys = inventory.public-keys;
  };
  enrich = import ./enrich.nix {
    inherit lib;
    hosts = inventory.hosts;
    realms = inventory.realms;
  };
}
