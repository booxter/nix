{
  context,
  factsModuleName,
  factsLib,
}:
factsLib.finalize {
  name = factsModuleName;
  facts = import ./facts.nix {
    inherit (context) frame mmini;
  };
}
