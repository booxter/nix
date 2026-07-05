{ ... }:
{
  imports = [
    ./cache-warmup.nix
    ./ups.nix
  ];

  programs.yubi = {
    age.enable = true;
    ssh.enable = true;
    smartCard.enable = true;
  };
}
