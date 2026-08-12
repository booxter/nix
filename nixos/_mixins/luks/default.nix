{
  config,
  lib,
  ...
}:
let
  cfg = config.host.luks;
  isPhysicalHost = !config.host.isVM;
in
{
  imports = [ ./remote-unlock.nix ];

  options.host.luks.enable = lib.mkEnableOption "LUKS-encrypted disk layout";

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      host.autoUpgrade.claims.luks.reboot.cadence = "never";
    })
    (lib.mkIf (isPhysicalHost && cfg.enable) (import ../disko/luks.nix { }))
    (lib.mkIf (isPhysicalHost && !cfg.enable) (import ../disko { }))
  ];
}
