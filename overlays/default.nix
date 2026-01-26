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
      pkgsRelease = getPkgs inputs.nixpkgs-25_11;
    in
    {
      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      # pull latest from nixpkgs; ignore what comes from rpi5 repo nixpkgs
      inherit (pkgs) netbootxyz-efi;

      # https://github.com/NixOS/nixpkgs/pull/477113
      inherit (pkgsMaster) ngrep;

      # Pull Sonarr from release-25.11 to test hang regressions
      inherit (pkgsRelease) sonarr;

      jellyfin = prev.jellyfin.overrideAttrs (oldAttrs: {
        patches = oldAttrs.patches or [ ] ++ [
          # Fix watched state not kept on Media replace/rename
          # https://github.com/jellyfin/jellyfin/pull/15899
          (prev.fetchpatch {
            url = "https://github.com/jellyfin/jellyfin/commit/09edca8b7a9174c374a7d03bb1ec3aea32d02ffd.patch";
            hash = "sha256-uC9RfhZK3BFT7K8gwgOvakPAp1Ti+bpfMzivVCLws64=";
            excludes = [ "CONTRIBUTORS.md" ];
          })
        ];
      });
    }
    // inputs.nixpkgs.lib.optionalAttrs prev.stdenv.isDarwin {
      # Pull NUT from master for now for darwin support.
      inherit (pkgsMaster) nut;
    };
}
