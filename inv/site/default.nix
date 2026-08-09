{
  context,
  hosts,
  inventoryLib,
  lib,
  nixCaches,
  readPublicKey,
}:
inventoryLib.finalize {
  facts = import ./facts.nix {
    inherit nixCaches readPublicKey;
    inherit (context) publicDomain;
  };
  enrich = import ./enrich.nix {
    inherit hosts lib;
    inherit (context) lanDnsRecordTtlSeconds lanDomain;
  };
  assertions = import ./asserts.nix { inherit lib; };
}
