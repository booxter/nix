{
  context,
  factsModuleName,
  facts,
  factsLib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix {
    inherit (context) lanDomain;
    publicKeys = facts.public-keys;
  };
}
