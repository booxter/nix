{
  context,
  hosts,
  inventoryLib,
  lib,
  readPublicKey,
  realms,
}:
inventoryLib.finalize {
  facts = import ./facts.nix {
    inherit readPublicKey;
    inherit (context) frame mmini;
  };
  enrich = import ./enrich.nix { inherit hosts lib realms; };
}
