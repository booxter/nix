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
      ./_mixins/avahi
      ./_mixins/auto-upgrade
      ./_mixins/backup-artifacts.nix
      ./_mixins/backup-metrics/default.nix
      ./_mixins/builder.nix
      ./_mixins/external-service.nix
      ./_mixins/firmware
      ./_mixins/internal-https-service.nix
      ./_mixins/lan-wan-accounting
      ./_mixins/nix
      ./_mixins/observability-client
      ./_mixins/proxmox
      ./_mixins/qos
      ./_mixins/restic-beast-client.nix
      ./_mixins/sso-oauth2-proxy-gate.nix
      ./_mixins/attic
      ./_mixins/unifi-sync
      ./_mixins/ups-client
      ./_mixins/ups-sched.nix
      ./_mixins/user
      ./_mixins/vm.nix
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
    security.sudo.wheelNeedsPassword = lib.mkDefault config.host.isWork;
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
