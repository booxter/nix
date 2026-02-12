{
  lib,
  pkgs,
  hostname,
  platform,
  stateVersion,
  upsShutdownDelaySeconds,
  ...
}:
let
  removePrefix = lib.strings.removePrefix;
  removeSuffix = lib.strings.removeSuffix;
  configName = ./${removePrefix "prox-" (removePrefix "local-" (removePrefix "ci-" hostname))};
  # TODO: for now just avahi but maybe consider simplifying hostnames in general
  avahiHostName = removeSuffix "vm" (removePrefix "prox-" hostname);
  upsClientsNAS = [
    "prx1-lab"
    "prx2-lab"
    "prx3-lab"
    "prox-cachevm"
    "prox-builder1vm"
    "prox-builder2vm"
    "prox-builder3vm"
    "prox-jellyfinvm"
    "prox-srvarrvm"
  ];
  upsClientsPi5 = [
    "beast"
    "nvws"
    "prox-nvvm"
  ];
in
{
  imports =
    lib.optionals (builtins.pathExists configName) [
      configName
    ]
    ++ [
      ./_mixins/user
    ]
    ++ lib.optionals (lib.elem hostname upsClientsNAS) [
      # TODO: rotate this password and migrate to sops-managed secrets.
      (import ./_mixins/ups-client {
        inherit pkgs upsShutdownDelaySeconds;
        monitorName = "nas";
        system = "ASUSTOR-UPS@nas-lab";
        user = "upsadmin";
        passwordText = "AdmUps1111";
      })
    ]
    ++ lib.optionals (lib.elem hostname upsClientsPi5) [
      # TODO: rotate this password and migrate to sops-managed secrets.
      (import ./_mixins/ups-client {
        inherit pkgs upsShutdownDelaySeconds;
        monitorName = "dhcp";
        system = "PI5-UPS@dhcp";
        user = "upsslave";
        passwordText = "upsslave123";
      })
    ];

  system.stateVersion = stateVersion;
  nixpkgs.hostPlatform = platform;

  nix.gc.dates = "Mon, 03:15";
  nix.optimise.dates = [ "Mon, 04:15" ];

  system.autoUpgrade = {
    enable = true;
    flake = "github:booxter/nix";
    flags = [
      "-L"
      "--show-trace"
    ];
    dates = lib.mkDefault "Sat 03:00";
    randomizedDelaySec = "45min";
    persistent = true;
  };

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

  # TODO: revisit hw sensor monitoring (sensord or alternative).

  environment.systemPackages = with pkgs; [
    ethtool
    pciutils
  ];

  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };

  hardware.enableRedistributableFirmware = true;
  services.fwupd.enable = true;
}
