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
      trusted-users = [
        "@admin"
        username
      ];

      # attic
      trusted-substituters = [
        "http://prox-cachevm:8080/default/"
      ];
      trusted-public-keys = [
        "default:+epFjzN1YKGqqeraQczdEfRyIuzgWd6/nrifa0467QQ="
      ];
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
