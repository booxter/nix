{ pkgs, ... }:
{
  users.users.jellyfin.extraGroups = [
    "render"
    "video"
  ];

  environment.systemPackages = with pkgs; [
    intel-gpu-tools
    libva-utils
  ];

  # Acceleration setup: https://nixos.wiki/wiki/Jellyfin
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
      vpl-gpu-rt
    ];
  };
}
