{
  lib,
  pkgs,
  ...
}:
{
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = lib.mkIf (
    pkgs.stdenv.hostPlatform.isx86_64 || pkgs.stdenv.hostPlatform.isi686
  ) true;

  services.fwupd.enable = true;
  # A Nordic 2.4 GHz USB receiver (VID:PID 1915:1025) can hang fwupd startup
  # via the nordic_hid plugin when it is plugged into a host.
  services.fwupd.daemonSettings.DisabledPlugins = [ "nordic_hid" ];
}
