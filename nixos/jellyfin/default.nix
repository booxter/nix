{ pkgs, ... }:
let
  movies = {
    device = "nas-lab:/volume2/Movies";
    fsType = "nfs";
  };
in
{
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  # NFS mounts with media
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems."/movies" = movies;
  virtualisation.vmVariant.virtualisation.fileSystems."/movies" = movies;

  # Acceleration setup: https://nixos.wiki/wiki/Jellyfin
  nixpkgs.config.packageOverrides = pkgs: {
    vaapiIntel = pkgs.vaapiIntel.override { enableHybridCodec = true; };
  };
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver # previously vaapiIntel
      vaapiVdpau
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
