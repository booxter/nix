{
  pkgs,
  ...
}:
{
  environment.systemPackages = [ pkgs.join-media-parts ];

  imports = [
    ./backup.nix
    ./nfs.nix
    ./paths.nix
  ];
}
