{
  pkgs,
  ...
}:
{
  imports = [
    ./backup-client.nix
    ./backup-server.nix
    ./jellyfin
    ./lolek.nix
  ];

  environment.systemPackages = with pkgs; [
    join-media-parts
  ];
}
