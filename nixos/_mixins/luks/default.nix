{
  config,
  lib,
  ...
}:
let
  enabled = config.host.disko.layout == "luks";
in
{
  imports = [ ./remote-unlock.nix ];

  config = lib.mkIf enabled {
    host.autoUpgrade.claims.luks.reboot.cadence = "never";
  };
}
