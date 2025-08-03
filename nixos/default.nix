{
  lib,
  hostname,
  platform,
  stateVersion,
  isVM,
  ...
}:
{
  imports = [
    ./${hostname}
    ./_mixins/user
  ]
  ++ lib.optionals isVM [
    ./_mixins/vm
  ];

  networking.useNetworkd = true;
  systemd.network.enable = true;

  system.stateVersion = stateVersion;
  nixpkgs.hostPlatform = platform;
}
