{
  context,
  factLibraryName,
  inventory,
  inventoryLib,
  lib,
  readPublicKey,
}:
inventoryLib.finalize {
  name = factLibraryName;
  facts = import ./facts.nix {
    inherit readPublicKey;
    inherit (context) frame mmini;
  };
  enrich = import ./enrich.nix {
    inherit lib;
    hosts = inventory.hosts;
    realms = inventory.realms;
  };
}
