{
  context,
  inventoryLib,
  lib,
  realms,
}:
inventoryLib.finalize {
  facts = import ./facts.nix {
    inherit lib;
    inherit (context) frame lanDomain;
  };
  enrich = import ./enrich.nix { inherit lib realms; };
  assertions = import ./asserts.nix { inherit lib; };
}
