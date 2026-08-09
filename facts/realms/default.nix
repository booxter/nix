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
    nixCaches = facts.nix-caches;
    publicCertificates = facts.public-certificates;
    publicKeys = facts.public-keys;
  };
}
