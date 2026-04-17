{ pkgs, ... }:
{
  # TODO: rotate these passwords and migrate to sops-managed secrets.
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = "BEAST-UPS";
      upsDescription = "APC Back-UPS RS 1500MS2";
      upsmonPasswordText = "upsmon123";
      upsslavePasswordText = "upsslave123";
      isCriticalNode = true;
    })
  ];
}
