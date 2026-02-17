{
  pkgs,
  ...
}:
let
  media = {
    device = "beast:/volume2/Media";
    fsType = "nfs";
  };
in
{
  services.jellyfin = {
    enable = false;
    openFirewall = false;
  };

  # NFS mounts with media
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems."/media" = media;
  virtualisation.vmVariant.virtualisation.fileSystems."/media" = media;

  # Acceleration setup: https://nixos.wiki/wiki/Jellyfin
  nixpkgs.config.packageOverrides = pkgs: {
    intel-vaapi-driver = pkgs.intel-vaapi-driver.override { enableHybridCodec = true; };
  };
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver # previously vaapiIntel
      libva-vdpau-driver
      libvdpau-va-gl
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
      vpl-gpu-rt # QSV on 11th gen or newer
    ];
  };

  # ports for local vm access
  virtualisation.vmVariant.virtualisation.forwardPorts = [
    {
      from = "host";
      guest.port = 8096;
      host.port = 8096;
    }
    {
      from = "host";
      guest.port = 8920;
      host.port = 8920;
    }
    {
      from = "host";
      guest.port = 7359;
      host.port = 7359;
    }
  ];
}
