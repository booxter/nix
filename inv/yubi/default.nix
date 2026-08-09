{
  context,
  inventoryLib,
}:
inventoryLib.finalize {
  facts = import ./facts.nix {
    inherit (context) frame mmini;
  };
}
