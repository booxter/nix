{
  config,
  lib,
  pkgs,
  ...
}:
{
  environment.systemPackages =
    (with pkgs; [
      ethtool
      pciutils
      usbutils
    ])
    ++ lib.optional (!config.host.isVM) pkgs.lm_sensors;
}
