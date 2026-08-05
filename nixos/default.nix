{
  config,
  hmFull,
  hostInventory,
  hostname,
  inputs,
  isDesktop,
  isVM,
  isWork,
  lib,
  pkgs,
  secretDomain,
  stateVersion,
  upsShutdownDelaySeconds,
  username,
  ...
}:
let
  hostSpec = hostInventory.nixosHostSpecsByName.${hostname};
  configName = ./${hostSpec.name};
  hostSecretFile = ../secrets + "/${secretDomain}/${hostname}.yaml";
  upsServerName = hostSpec.upsHost or null;
  upsServerSpec =
    if upsServerName == null then null else hostInventory.nixosHostSpecsByName.${upsServerName};
  useLiteralUpsPassword =
    upsServerSpec != null && ((hostSpec.isWork or false) || (upsServerSpec.isWork or false));
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
    ++ lib.optionals (builtins.pathExists configName) [
      configName
    ]
    ++ [
      ./_mixins/avahi
      ./_mixins/auto-upgrade
      ./_mixins/backup-artifacts.nix
      ./_mixins/backup-metrics/default.nix
      ./_mixins/external-service.nix
      ./_mixins/internal-https-service.nix
      ./_mixins/lan-wan-accounting
      ./_mixins/nix
      ./_mixins/observability-client
      ./_mixins/proxmox
      ./_mixins/resource-control.nix
      ./_mixins/restic-beast-client.nix
      ./_mixins/sso-oauth2-proxy-gate.nix
      ./_mixins/unifi-sync
      ./_mixins/user
    ]
    ++ lib.optionals (!isVM) [
      ./_mixins/firmware
    ]
    ++ lib.optionals (!(hostSpec.isWork or false)) [
      ./_mixins/attic
    ]
    ++ lib.optionals (upsServerSpec != null) [
      (import ./_mixins/ups-client (
        {
          inherit pkgs upsShutdownDelaySeconds;
          monitorName = upsServerSpec.name;
          system = "${hostInventory.toUpsName upsServerSpec.name}@${hostInventory.toHostIpv4Address upsServerSpec}";
          user = "upsslave";
        }
        // lib.optionalAttrs useLiteralUpsPassword {
          passwordText = "upsslave123";
        }
      ))
    ];

    system.stateVersion = stateVersion;
    home-manager = {
      extraSpecialArgs = {
        inherit
          hmFull
          hostInventory
          hostname
          inputs
          isDesktop
          isWork
          stateVersion
          username
          ;
      };
      useGlobalPkgs = true;
      useUserPackages = true;
      users.${username} = ../hm;
    };
    virtualisation.containers.enable = true;
    security.sudo.wheelNeedsPassword = lib.mkDefault config.host.isWork;
    host.isCritical = lib.mkDefault (hostSpec.critical or false);

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
    sops.defaultSopsFile = lib.mkDefault hostSecretFile;
    # Install regular secrets through a sysinit unit so services that consume
    # them can order themselves after sops-install-secrets.service. Password
    # secrets marked neededForUsers still use the early users activation path.
    sops.useSystemdActivation = lib.mkDefault true;
  }
)
