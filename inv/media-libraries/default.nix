{ inventoryLib }:
inventoryLib.finalize {
  facts = import ./facts.nix;
}
