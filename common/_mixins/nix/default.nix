{ pkgs, ... }:
{
  nix = {
    package = pkgs.lix;
    settings = {
      experimental-features = "nix-command flakes";
      trusted-users = [ "@admin" ];
    };
  };
}
