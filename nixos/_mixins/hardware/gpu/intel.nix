{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (builtins.elem "intel" config.host.hardware.gpu.vendors) {
    environment.systemPackages = with pkgs; [
      intel-gpu-tools
      libva-utils
    ];

    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        intel-compute-runtime
        vpl-gpu-rt
      ];
    };
  };
}
