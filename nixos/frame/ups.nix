{ pkgs, hostInventory, ... }:
let
  frameSpec = hostInventory.nixosHosts.frame;
in
{
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = hostInventory.toUpsName frameSpec.name;
      upsDescription = "APC UPS 1500VA";
      upsShutdownDelaySeconds = 600;
    })
  ];
}
