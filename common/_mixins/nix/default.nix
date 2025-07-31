{ pkgs, outputs, ... }:
{
  nix = {
    package = pkgs.lix;
    settings = {
      experimental-features = "nix-command flakes";
      trusted-users = [ "@admin" ];
    };
  };

  nixpkgs = {
    overlays = [
      outputs.overlays.additions
      outputs.overlays.modifications
      outputs.overlays.unstable-packages
      outputs.overlays.master-packages
    ];
    config = {
      allowUnfree = true;
    };
  };
}
