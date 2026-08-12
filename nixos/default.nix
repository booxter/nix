{
  config,
  facts,
  hostSpec,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  hostname = hostSpec.name;
  username = config.host.username;
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
      ./_mixins/avahi
      ./_mixins/auto-upgrade
      ./_mixins/aurral
      ./_mixins/backups
      ./_mixins/builder.nix
      ./_mixins/desktop
      ./_mixins/external-service.nix
      ./_mixins/hardware
      ./_mixins/internal-https-service
      ./_mixins/jellarr
      ./_mixins/jellyfin
      ./_mixins/lan-wan-accounting
      ./_mixins/lolek
      ./_mixins/luks
      ./_mixins/maintenance
      ./_mixins/network
      ./_mixins/nix
      ./_mixins/observability
      ./_mixins/ollama
      ./_mixins/proxmox
      ./_mixins/qos
      ./_mixins/security
      ./_mixins/sso
      ./_mixins/storage
      ./_mixins/site-ip
      ./_mixins/ups-client
      ./_mixins/ups-server.nix
      ./_mixins/ups-sched.nix
      ./_mixins/user
      ./_mixins/vm.nix
      ./_mixins/vpn
      ./_mixins/watchstate
      ./_mixins/web
      ./_mixins/wireguard
    ];

    home-manager = {
      extraSpecialArgs = {
        inherit
          facts
          hostSpec
          inputs
          ;
      };
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${username} = {
        imports = [ ../hm ];
        home.stateVersion = config.system.stateVersion;
      };
    };
    virtualisation.containers.enable = true;
    security.sudo.wheelNeedsPassword = lib.mkDefault config.host.security.sudo.wheelNeedsPassword;
    time.timeZone = "America/New_York";

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
