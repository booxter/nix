{
  factsModuleName,
  factsLib,
  lib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix { inherit lib; };
}
