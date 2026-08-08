{
  pkgs,
  ...
}:
{
  environment.systemPackages = [ pkgs.join-media-parts ];

  imports = [
    ./backup.nix
    ./nfs.nix
    ./oauth2-proxy.nix
    ./paths.nix
  ];
}
