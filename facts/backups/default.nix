{
  factsModuleName,
  facts,
  factsLib,
  lib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix { publicKeys = facts.public-keys; };
  enrich = import ./enrich.nix { inherit lib; };
  assertions = import ./asserts.nix { inherit lib; };
}
