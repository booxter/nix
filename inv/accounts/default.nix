{ inventoryLib, lib }:
inventoryLib.finalize {
  facts = import ./facts.nix;
  assertions = import ./asserts.nix { inherit lib; };
}
