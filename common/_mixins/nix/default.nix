{
  lib,
  pkgs,
  outputs,
  username,
  ...
}:
{
  nix = {
    package = lib.mkForce pkgs.lix;
    settings = {
      experimental-features = "nix-command flakes";
      trusted-users = [ "@admin" username ];
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
