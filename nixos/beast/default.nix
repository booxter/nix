{
  pkgs,
  ...
}:
{
  imports = [
    ./jellyfin
    ./lolek.nix
  ];

  environment.systemPackages = with pkgs; [
    join-media-parts
  ];
}
