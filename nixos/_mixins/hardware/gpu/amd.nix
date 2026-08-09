{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (builtins.elem "amd" config.hardware.gpu) {
    environment.systemPackages = with pkgs; [
      amdgpu_top
      clinfo
      radeontop
    ];
  };
}
