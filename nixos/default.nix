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
  configName = ./${removePrefix "prox-" (removePrefix "local-" hostname)};
in
{
  imports =
    lib.optionals (builtins.pathExists configName) [
      configName
    ]
    ++ [
      ./_mixins/user
    ]
    ++ lib.optionals isDesktop [
      ./_mixins/desktop
    ];

  system.stateVersion = stateVersion;
  nixpkgs.hostPlatform = platform;

  nix.gc.dates = "Mon, 03:15";
  nix.optimise.dates = [ "Mon, 04:15" ];

  time.timeZone = "America/New_York";

  networking.dhcpcd.extraConfig = ''
    clientid ${hostname}
  '';

  environment.systemPackages = with pkgs; [
    pciutils
  ];
}
