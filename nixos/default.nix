{
  config,
  hostInventory,
  hostSpec,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  hostname = hostSpec.name;
  username = hostSpec.username;
in
(
  {
    imports = [
      inputs.stylix.nixosModules.stylix
      ../common
      inputs.disko.nixosModules.disko
      inputs.sops-nix.nixosModules.sops
      inputs.home-manager.nixosModules.home-manager
    ]
    ++ [
      ./_mixins/adaptive-upload-policy
      ./_mixins/alertmanager
      ./_mixins/alertmanager-watchdog
      ./_mixins/attic
      ./_mixins/auto-upgrade
      ./_mixins/avahi
      ./_mixins/backups
      ./_mixins/btrfs
      ./_mixins/builder.nix
      ./_mixins/degoog
      ./_mixins/desktop-environment.nix
      ./_mixins/disko
      ./_mixins/ethernet-pause.nix
      ./_mixins/external-service.nix
      ./_mixins/firmware
      ./_mixins/grafana
      ./_mixins/gpu
      ./_mixins/home-assistant
      ./_mixins/internal-https-service.nix
      ./_mixins/jellyfin
      ./_mixins/lan-wan-accounting
      ./_mixins/llm
      ./_mixins/lolek
      ./_mixins/loki.nix
      ./_mixins/md-raid.nix
      ./_mixins/media-storage.nix
      ./_mixins/netboot.nix
      ./_mixins/nix
      ./_mixins/nfs
      ./_mixins/observability
      ./_mixins/paperless
      ./_mixins/paperless-gpt
      ./_mixins/pki
      ./_mixins/proxmox
      ./_mixins/public-ingress.nix
      ./_mixins/qos
      ./_mixins/remote-gui
      ./_mixins/remote-unlock.nix
      ./_mixins/smart-storage.nix
      ./_mixins/sso
      ./_mixins/storage-observability
      ./_mixins/storage.nix
      ./_mixins/unifi-sync
      ./_mixins/unpoller.nix
      ./_mixins/uptimerobot-sync
      ./_mixins/ups
      ./_mixins/user
      ./_mixins/vikunja
      ./_mixins/vm.nix
      ./_mixins/wireguard-endpoint
      ./_mixins/yubi.nix
    ];

    home-manager = {
      extraSpecialArgs = {
        inherit
          hostInventory
          hostSpec
          inputs
          ;
      };
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${username} = ../hm;
    };
    virtualisation.containers.enable = true;
    # VM variants use synthetic filesystems rather than the host's physical storage.
    virtualisation.vmVariant.host.storage.useInventory = false;
    security.sudo.wheelNeedsPassword = lib.mkDefault config.host.management.sudoWheelNeedsPassword;
    time.timeZone = hostInventory.regional.timeZone;
    i18n.defaultLocale = hostInventory.regional.posixLocale;

    services.xserver.autoRepeatDelay = 210; # ms before repeat starts (macOS InitialKeyRepeat=14)
    services.xserver.autoRepeatInterval = 30; # ms between repeats (macOS KeyRepeat=1)

    networking.dhcpcd.extraConfig = ''
      clientid ${hostname}
    '';
    # All current NFS use is v4-only. NixOS enables rpcbind automatically for
    # NFS filesystems, but rpcbind is only needed for legacy NFSv3/RPC helpers.
    services.rpcbind.enable = lib.mkOverride 75 false;

    # TODO: revisit hw sensor monitoring (sensord or alternative).

    environment.systemPackages = with pkgs; [
      ethtool
      pciutils
      procps
      psmisc
      usbutils
    ];

  }
  // {
    # Install regular secrets through a sysinit unit so services that consume
    # them can order themselves after sops-install-secrets.service. Password
    # secrets marked neededForUsers still use the early users activation path.
    sops.useSystemdActivation = lib.mkDefault true;
  }
)
