{
  context,
  inventoryLib,
  readPublicKey,
}:
inventoryLib.finalize {
  facts = import ./facts.nix {
    inherit readPublicKey;
    inherit (context) lanDomain;
  };
}
