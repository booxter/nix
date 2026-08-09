{
  factsModuleName,
  factsLib,
  lib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix;
  assertions = import ./asserts.nix { inherit lib; };
}
