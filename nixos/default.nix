{
  lib,
  hostname,
  platform,
  stateVersion,
  ...
}:
let
  removePrefix = lib.strings.removePrefix;
  configName = removePrefix "prox-" (removePrefix "local-" hostname);
in
{
  imports = [
    ./${configName}
    ./_mixins/user
  ];

  system.stateVersion = stateVersion;
  nixpkgs.hostPlatform = platform;

  nix.gc.dates = "Mon, 03:15";
  nix.optimise.dates = "Mon, 04:15";
}
