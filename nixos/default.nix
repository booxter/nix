{
  lib,
  pkgs,
  hostname,
  platform,
  stateVersion,
  ...
}:
let
  removePrefix = lib.strings.removePrefix;
  configName = ./${removePrefix "prox-" (removePrefix "local-" (removePrefix "ci-" hostname))};
in
{
  imports =
    lib.optionals (builtins.pathExists configName) [
      configName
    ]
    ++ [
      ./_mixins/user
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

  environment.systemPackages = with pkgs; [
    pciutils
  ];

  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };
}
