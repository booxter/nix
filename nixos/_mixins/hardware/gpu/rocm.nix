{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.hardware.gpu.compute == "rocm") {
    environment.systemPackages = with pkgs.rocmPackages; [
      rocm-smi
      rocminfo
    ];
    nixpkgs.config.rocmSupport = true;
  };
}
