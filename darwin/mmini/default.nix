{ ... }:
{
  imports = [
    ./cache-warmup.nix
    ./ups.nix
  ];

  programs.yubi = {
    ssh.enable = true;
    smartCard.enable = true;
  };
}
