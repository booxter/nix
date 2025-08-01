{ lib, hostname, platform, stateVersion, isVM, ... }:
{
  imports = [
    ./${hostname}
    ./_mixins/user
    ./_mixins/zsh
  ]
  ++ lib.optionals isVM [
    ./_mixins/vm
  ];

  system.stateVersion = stateVersion;
  nixpkgs.hostPlatform = platform;
}

