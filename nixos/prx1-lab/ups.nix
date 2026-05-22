{ pkgs, hostInventory, ... }:
let
  prx1Spec = hostInventory.nixosHostSpecsByName."prx1-lab";
in
{
  # TODO: rotate these passwords and migrate to sops-managed secrets.
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = prx1Spec.upsName;
      upsDescription = "APC UPS 1500VA";
      upsmonPasswordText = "upsmon123";
      upsslavePasswordText = "upsslave123";
      isCriticalNode = true;
    })
  ];
}
