{
  factsModuleName,
  facts,
  factsLib,
  lib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix;
  enrich = import ./enrich.nix {
    accounts = facts.accounts;
    sharedStorage = facts.shared-storage;
    inherit lib;
  };
  assertions = import ./asserts.nix {
    inherit lib;
    sharedStorage = facts.shared-storage;
  };
}
