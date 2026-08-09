{
  factsModuleName,
  facts,
  factsLib,
  lib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix { mediaLibraries = facts.media-libraries; };
  enrich = import ./enrich.nix {
    accounts = facts.accounts;
    inherit lib;
  };
  assertions = import ./asserts.nix { inherit lib; };
}
