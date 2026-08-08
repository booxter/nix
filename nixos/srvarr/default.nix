{
  pkgs,
  ...
}:
{
  environment.systemPackages = [ pkgs.join-media-parts ];

  imports = [
    ./backup.nix
    ./paths.nix
  ];
}
