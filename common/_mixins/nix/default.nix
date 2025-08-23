{
  lib,
  pkgs,
  outputs,
  ...
}:
{
  nix = {
    package = lib.mkForce pkgs.lix;
    settings = {
      experimental-features = "nix-command flakes";
      trusted-users = [ "@admin" ];
    };
  };

  nixpkgs = {
    overlays = [
      outputs.overlays.additions
      outputs.overlays.modifications
    ];
    config = {
      allowUnfree = true;
    };
  };
}
