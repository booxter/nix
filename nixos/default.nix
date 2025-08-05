{
  hostname,
  platform,
  stateVersion,
  ...
}:
{
  imports = [
    ./${hostname}
    ./_mixins/user
  ];

  system.stateVersion = stateVersion;
  nixpkgs.hostPlatform = platform;
}
