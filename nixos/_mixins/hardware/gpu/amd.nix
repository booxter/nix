{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.host.hardware.gpu.vendor == "amd") {
    environment.systemPackages = with pkgs; [
      amdgpu_top
      clinfo
      radeontop
    ];
  };
}
