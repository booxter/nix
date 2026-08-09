{
  accounts,
  inventoryLib,
  lib,
  sharedStorage,
}:
inventoryLib.finalize {
  facts = import ./facts.nix;
  enrich = import ./enrich.nix {
    inherit
      accounts
      lib
      sharedStorage
      ;
  };
  assertions = import ./asserts.nix { inherit lib sharedStorage; };
}
