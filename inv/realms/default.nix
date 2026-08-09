{
  context,
  inventoryLib,
  nixCaches,
  readPublicKey,
}:
inventoryLib.finalize {
  facts = import ./facts.nix {
    inherit nixCaches readPublicKey;
    inherit (context) lanDomain;
  };
}
