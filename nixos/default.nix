{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
(
  {
    imports = [
      inputs.stylix.nixosModules.stylix
      ../common
      inputs.disko.nixosModules.disko
      inputs.sops-nix.nixosModules.sops
    ]
    ++ [
      ./_mixins/adaptive-upload-policy
      ./_mixins/avahi
      ./_mixins/auto-upgrade
      ./_mixins/audiobookshelf
      ./_mixins/aurral
      ./_mixins/backups
      ./_mixins/bazarr
      ./_mixins/desktop
      ./_mixins/degoog
      ./_mixins/downloads
      ./_mixins/disko
      ./_mixins/glance
      ./_mixins/hardware
      ./_mixins/hermes-agent
      ./_mixins/hm
      ./_mixins/home-assistant
      ./_mixins/houndarr
      ./_mixins/jellyfin
      ./_mixins/lan-wan-accounting
      ./_mixins/lidarr
      ./_mixins/lolek
      ./_mixins/mailer
      ./_mixins/maintenance
      ./_mixins/media-admin-sso
      ./_mixins/media-libraries
      ./_mixins/motion-captcha-bot
      ./_mixins/network
      ./_mixins/nix
      ./_mixins/observability
      ./_mixins/ollama
      ./_mixins/paperless
      ./_mixins/pinepods
      ./_mixins/pki
      ./_mixins/proxmox
      ./_mixins/prowlarr
      ./_mixins/qos
      ./_mixins/radarr
      ./_mixins/remote-control
      ./_mixins/romm
      ./_mixins/sabnzbd
      ./_mixins/security
      ./_mixins/seerr
      ./_mixins/shelfmark
      ./_mixins/sso
      ./_mixins/storage
      ./_mixins/transmission
      ./_mixins/site-ip
      ./_mixins/sonarr
      ./_mixins/ups
      ./_mixins/user
      ./_mixins/vikunja
      ./_mixins/vm.nix
      ./_mixins/vpn
      ./_mixins/watchstate
      ./_mixins/web
      ./_mixins/wireguard
    ];

    virtualisation.containers.enable = true;
    time.timeZone = config.host.site.timeZone;

    environment.systemPackages = with pkgs; [
      procps
      psmisc
    ];

  }
  // {
    # Install regular secrets through a sysinit unit so services that consume
    # them can order themselves after sops-install-secrets.service. Password
    # secrets marked neededForUsers still use the early users activation path.
    sops.useSystemdActivation = lib.mkDefault true;
  }
)
