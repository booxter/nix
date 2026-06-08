{ pkgs, hostInventory, ... }:
let
  nvwsSpec = hostInventory.nixosHostSpecsByName.nvws;
in
{
  # Work UPS credentials intentionally stay literal.
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = hostInventory.toUpsName nvwsSpec.name;
      upsDescription = "APC UPS 1500VA";
      upsmonPasswordText = "upsmon123";
      upsslavePasswordText = "upsslave123";
      isCriticalNode = true;
    })
  ];
}
