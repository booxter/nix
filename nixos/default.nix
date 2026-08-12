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
      ./_mixins/accounts
      ./_mixins/adaptive-upload-policy
      ./_mixins/avahi
      ./_mixins/auto-upgrade
      ./_mixins/aurral
      ./_mixins/backups
      ./_mixins/builder.nix
      ./_mixins/desktop
      ./_mixins/external-service.nix
      ./_mixins/hardware
      ./_mixins/hm
      ./_mixins/home-assistant
      ./_mixins/internal-https-service
      ./_mixins/jellarr
      ./_mixins/jellyfin
      ./_mixins/lan-wan-accounting
      ./_mixins/lolek
      ./_mixins/luks
      ./_mixins/mailer
      ./_mixins/maintenance
      ./_mixins/network
      ./_mixins/nix
      ./_mixins/observability
      ./_mixins/ollama
      ./_mixins/paperless
      ./_mixins/proxmox
      ./_mixins/qos
      ./_mixins/security
      ./_mixins/sso
      ./_mixins/storage
      ./_mixins/site-ip
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

    services.xserver.autoRepeatDelay = 210; # ms before repeat starts (macOS InitialKeyRepeat=14)
    services.xserver.autoRepeatInterval = 30; # ms between repeats (macOS KeyRepeat=1)

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
