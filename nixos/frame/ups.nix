{ pkgs, hostInventory, ... }:
let
  frameSpec = hostInventory.nixosHostSpecsByName.frame;
in
{
  # TODO: rotate these passwords and migrate to sops-managed secrets.
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = hostInventory.toUpsName frameSpec.name;
      upsDescription = "APC UPS 1500VA";
      upsShutdownDelaySeconds = 600;
      upsmonPasswordText = "upsmon234";
      upsslavePasswordText = "upsslave234";
    })
  ];
}
