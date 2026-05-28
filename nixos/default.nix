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
  # TODO: for now just avahi but maybe consider simplifying hostnames in general
  avahiHostName = removeSuffix "vm" (removePrefix "prox-" hostname);
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
        ./_mixins/internal-https-service.nix
        ./_mixins/backup-metrics/default.nix
        ./_mixins/observability-client
        ./_mixins/external-service.nix
        ./_mixins/lan-wan-accounting
        ./_mixins/nixos-upgrade-holds
        ./_mixins/nixos-upgrade-metrics
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
    security.sudo.wheelNeedsPassword = config.host.isWork;

    nix.gc.dates = "Mon, 03:15";
    nix.optimise.dates = [ "Mon, 04:15" ];
    nix.optimise.randomizedDelaySec = "5min";

    system.autoUpgrade = {
      enable = true;
      flake = "github:booxter/nix";
      flags = [
        "-L"
        "--show-trace"
      ];
      # Run inherited daily upgrades after the Monday Proxmox node window.
      dates = lib.mkDefault "05:15";
      randomizedDelaySec = "5min";
      persistent = false;
      allowReboot = true;
      rebootWindow = {
        lower = "01:00";
        upper = "06:00";
      };
    };

    host.autoUpgrade.holds = [
      {
        startDate = "2026-06-08";
        stopDate = "2026-06-28";
      }
    ];

    time.timeZone = "America/New_York";

    services.xserver.autoRepeatDelay = 210; # ms before repeat starts (macOS InitialKeyRepeat=14)
    services.xserver.autoRepeatInterval = 30; # ms between repeats (macOS KeyRepeat=1)

    networking.dhcpcd.extraConfig = ''
      clientid ${hostname}
    '';

    services.avahi = {
      enable = true;
      # NixOS uses separate knobs for v4/v6 NSS.
      nssmdns4 = true;
      nssmdns6 = true;
      # Ensure this host publishes its name/address over mDNS.
      publish = {
        enable = true;
        addresses = true;
      };
      hostName = avahiHostName;
    };

    host.observability.client = {
      enable = lib.mkDefault (!config.host.isWork);
      lokiWriteUrl = lib.mkDefault "https://loki.${hostInventory.site.lan.domain}/loki/api/v1/push";
      loki.mtls.enable = lib.mkDefault (!config.host.isWork);
      mtlsClients.loki = {
        enable = lib.mkDefault (!config.host.isWork);
        secretPrefix = "observability/clients/loki";
      };
      nodeExporter.mtls.enable = lib.mkDefault (!isLocalVmHost && hostname != "prox-fanavm");
    };

    host.observability.nixosUpgrade = {
      enable = lib.mkDefault true;
      exportToNodeExporter = lib.mkDefault (!config.host.isWork);
    };

    host.observability.lanWan = {
      enable = lib.mkDefault (!config.host.isWork);
      mode = lib.mkDefault (if config.host.isProxmox then "host-local" else "interface-path");
    };

    # TODO: revisit hw sensor monitoring (sensord or alternative).

    environment.systemPackages = with pkgs; [
      ethtool
      pciutils
      psmisc
    ];

    systemd.services.nix-daemon.serviceConfig = {
      MemoryAccounting = true;
      MemoryMax = "90%";
      OOMScoreAdjust = 500;
    };

    hardware.enableRedistributableFirmware = true;
    hardware.cpu.intel.updateMicrocode = lib.mkIf (
      pkgs.stdenv.hostPlatform.isx86_64 || pkgs.stdenv.hostPlatform.isi686
    ) true;
    services.fwupd.enable = true;
    # A Nordic 2.4 GHz USB receiver (VID:PID 1915:1025) can hang fwupd startup
    # via the nordic_hid plugin when it is plugged into a host.
    services.fwupd.daemonSettings.DisabledPlugins = [ "nordic_hid" ];

  }
  // {
    sops.defaultSopsFile = lib.mkDefault hostSecretFile;
  }
)
