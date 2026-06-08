{ pkgs, hostInventory, ... }:
let
  prx1Spec = hostInventory.nixosHostSpecsByName."prx1-lab";
in
{
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = hostInventory.toUpsName prx1Spec.name;
      upsDescription = "APC UPS 1500VA";
      isCriticalNode = true;
    })
  ];
}
