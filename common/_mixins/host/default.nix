{
  hostName,
  system,
  ...
}:
{
  imports = [
    ./home.nix
    ./options.nix
    ./work.nix
  ];

  config = {
    nixpkgs.hostPlatform = system;
    networking.hostName = hostName;
  };
}
