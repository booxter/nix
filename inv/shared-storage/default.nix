{
  accounts,
  inventoryLib,
  lib,
  mediaLibraries,
}:
inventoryLib.finalize {
  facts = import ./facts.nix { inherit mediaLibraries; };
  enrich = import ./enrich.nix { inherit accounts lib; };
  assertions = import ./asserts.nix { inherit lib; };
}
