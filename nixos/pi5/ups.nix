{ pkgs, hostInventory, ... }:
let
  pi5Spec = hostInventory.nixosHostSpecsByName.pi5;
in
{
  # TODO: rotate these passwords and migrate to sops-managed secrets.
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = pi5Spec.upsName;
      upsDescription = "APC UPS 1500VA";
      upsmonPasswordText = "upsmon123";
      upsslavePasswordText = "upsslave123";
      isCriticalNode = true;
    })
  ];
}
