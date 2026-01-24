{ pkgs, ... }:
{
  # TODO: rotate these passwords and migrate to sops-managed secrets.
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = "FRAME-UPS";
      upsDescription = "APC UPS 1500VA";
      shutdownDelaySeconds = 600;
      upsmonPasswordText = "upsmon234";
      upsslavePasswordText = "upsslave234";
    })
  ];
}
