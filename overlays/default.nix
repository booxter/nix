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
      pkgsHuntarr = getPkgs inputs.nixpkgs-huntarr;
    in
    {
      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      # pull latest from nixpkgs; ignore what comes from rpi5 repo nixpkgs
      inherit (pkgs) netbootxyz-efi;

      # Pull Sonarr and Readarr from release-25.11 to test hang regressions
      # TODO: report issues; investigate; fix
      inherit (pkgsRelease) readarr sonarr;

      # Huntarr from fork until it lands upstream
      inherit (pkgsHuntarr) huntarr;
    }
    // inputs.nixpkgs.lib.optionalAttrs prev.stdenv.isDarwin {
      # Pull NUT from master for now for darwin support.
      inherit (pkgsMaster) nut;
    };
}
