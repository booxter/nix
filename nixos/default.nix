{ platform, ... }:
{
  imports = [];

  nixpkgs.hostPlatform = platform;
}

