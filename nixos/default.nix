{
  lib,
  pkgs,
  hostname,
  platform,
  stateVersion,
  isDesktop,
  ...
}:
let
  removePrefix = lib.strings.removePrefix;
  configName = ./${removePrefix "prox-" (removePrefix "local-" (removePrefix "ci-" hostname))};
  upsClients = [
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
in
{
  imports =
    lib.optionals (builtins.pathExists configName) [
      configName
    ]
    ++ [
      ./_mixins/user
    ]
    ++ lib.optionals (lib.elem hostname upsClients) [
      ./_mixins/ups-client
    ]
    ++ lib.optionals isDesktop [
      ./_mixins/desktop
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
