{
  lib,
  pkgs,
  hostname,
  upsCriticalHosts,
  ...
}:
{
  # TODO: rotate these passwords and migrate to sops-managed secrets.
  imports = [
    (import ../_mixins/ups-server.nix {
      inherit pkgs;
      upsName = "FRAME-UPS";
      upsDescription = "APC UPS 1500VA";
      upsShutdownDelaySeconds = 600;
      upsmonPasswordText = "upsmon234";
      upsslavePasswordText = "upsslave234";
      isCriticalNode = lib.elem hostname upsCriticalHosts;
    })
  ];
}
