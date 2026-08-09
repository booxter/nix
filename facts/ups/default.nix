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
    inherit lib;
    hosts = facts.hosts;
  };
}
