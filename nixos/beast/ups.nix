{ pkgs, hostInventory, ... }:
let
  beastSpec = hostInventory.nixosHostSpecsByName.beast;
in
{
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = hostInventory.toUpsName beastSpec.name;
      upsDescription = "APC Back-UPS RS 1500MS2";
      isCriticalNode = true;
    })
  ];
}
