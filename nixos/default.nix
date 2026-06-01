{
  config,
  lib,
  pkgs,
  hostname,
  hostInventory,
  platform,
  stateVersion,
  upsShutdownDelaySeconds,
  ...
}:
let
  removePrefix = lib.strings.removePrefix;
  removeSuffix = lib.strings.removeSuffix;
  hostSpecName = removeSuffix "vm" (removePrefix "prox-" (removePrefix "local-" hostname));
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};
  configName = ./${removePrefix "prox-" (removePrefix "local-" hostname)};
  hostSecretFile = ../secrets + "/${hostname}.yaml";
  isLocalVmHost = lib.hasPrefix "local-" hostname && lib.hasSuffix "vm" hostname;
  upsServerName = if isLocalVmHost then null else hostSpec.upsHost or null;
  upsServerSpec =
    if upsServerName == null then null else hostInventory.nixosHostSpecsByName.${upsServerName};
in
(
  {
    imports =
      lib.optionals (builtins.pathExists configName) [
        configName
      ]
      ++ [
        ./_mixins/avahi
        ./_mixins/auto-upgrade
        ./_mixins/backup-metrics/default.nix
        ./_mixins/external-service.nix
        ./_mixins/firmware
        ./_mixins/internal-https-service.nix
        ./_mixins/lan-wan-accounting
        ./_mixins/nix
        ./_mixins/observability-client
        ./_mixins/restic-beast-client.nix
        ./_mixins/user
      ]
      ++ lib.optionals (!(hostSpec.isWork or false)) [
        ./_mixins/attic
      ]
      ++ lib.optionals (upsServerSpec != null) [
        # TODO: rotate this password and migrate to sops-managed secrets.
        (import ./_mixins/ups-client {
          inherit pkgs upsShutdownDelaySeconds;
          monitorName = upsServerSpec.name;
          system = "${hostInventory.toUpsName upsServerSpec.name}@${
            upsServerSpec.dnsName or upsServerSpec.name
          }";
          user = "upsslave";
          passwordText = "upsslave123";
        })
      ];

    system.stateVersion = stateVersion;
    nixpkgs.hostPlatform = platform;
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
      psmisc
    ];

  }
  // {
    sops.defaultSopsFile = lib.mkDefault hostSecretFile;
  }
)
