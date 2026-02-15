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
      upsName = "PRX1-UPS";
      upsDescription = "APC UPS 1500VA";
      upsmonPasswordText = "upsmon123";
      upsslavePasswordText = "upsslave123";
      isCriticalNode = lib.elem hostname upsCriticalHosts;
    })
  ];
}
