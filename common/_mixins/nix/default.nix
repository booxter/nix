{
  lib,
  pkgs,
  outputs,
  username,
  isWork,
  ...
}:
{
  nix = let
    cacheUrl = "http://prox-cachevm:8080/default/";
    cacheKey = "default:+epFjzN1YKGqqeraQczdEfRyIuzgWd6/nrifa0467QQ=";
  in {
    package = lib.mkForce pkgs.lix;
    settings = {
      experimental-features = "nix-command flakes";
      trusted-users = [
        "@admin"
        username
      ];
    } // lib.optionalAttrs (!isWork) {
      # attic
      substituters = [ cacheUrl ];
      trusted-public-keys = [ cacheKey ];
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
