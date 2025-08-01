{ lib, hostname, platform, stateVersion, isVM, ... }:
{
  imports = [
    ./${hostname}
  ]
  ++ lib.optionals isVM [
    ./_mixins/user
    ./_mixins/vm
    ./_mixins/zsh
  ];

  system.stateVersion = stateVersion;
  nixpkgs.hostPlatform = platform;
}

