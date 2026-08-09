{
  context,
  factsModuleName,
  facts,
  factsLib,
  lib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix {
    inherit lib;
    inherit (context) frame lanDomain;
  };
  enrich = import ./enrich.nix {
    inherit lib;
    realms = facts.realms;
    inherit (context) lanDomain;
  };
  assertions = import ./asserts.nix { inherit lib; };
}
