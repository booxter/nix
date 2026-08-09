{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (builtins.elem "amd" config.host.hardware.gpu.vendors) {
    environment.systemPackages = with pkgs; [
      amdgpu_top
      clinfo
      radeontop
    ];
  };
}
