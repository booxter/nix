{ inputs, ... }:
{
  additions = final: _prev: import ../pkgs final.pkgs;

  modifications =
    _final: prev:
    let
      getPkgs =
        np:
        import np {
          inherit (prev) system;
          config = {
            allowUnfree = true;
          };
        };

      pkgs = getPkgs inputs.nixpkgs;
      pkgsLldb = getPkgs inputs.debugserver;
      pkgsMaster = getPkgs inputs.nixpkgs-master;
    in
    {
      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      # pull latest from nixpkgs; ignore what comes from rpi5 repo nixpkgs
      inherit (pkgs) netbootxyz-efi;

      # https://github.com/NixOS/nixpkgs/pull/477113
      inherit (pkgsMaster) ngrep;

      jellyfin = prev.jellyfin.overrideAttrs (oldAttrs: {
        patches = oldAttrs.patches or [ ] ++ [
          # Fix watched state not kept on Media replace/rename
          # https://github.com/jellyfin/jellyfin/pull/15899
          (prev.fetchurl {
            url = "https://github.com/jellyfin/jellyfin/pull/15899.patch";
            hash = "sha256-PuPpaOyp45ehbzpHcG372QxnXRc49cG70hglpMuvcGc=";
          })
        ];
      });
    };
}
