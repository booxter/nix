{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.host.hardware.gpu.compute == "rocm") {
    environment.systemPackages = with pkgs.rocmPackages; [
      rocm-smi
      rocminfo
    ];
    nixpkgs.config.rocmSupport = true;
  };
}
