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
    inherit (context) frame mmini;
    publicKeys = facts.public-keys;
  };
  enrich = import ./enrich.nix {
    inherit lib;
    hosts = facts.hosts;
    realms = facts.realms;
  };
}
