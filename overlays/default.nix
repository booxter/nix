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
      pkgsNut = getPkgs inputs.nixpkgs-nut;
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

      # Pull NUT from the darwin-enabled fork on macOS only.
      nut = if prev.stdenv.hostPlatform.isDarwin then pkgsNut.nut else prev.nut;

      # Pull firefox from release-25.11 because it timed out in Hydra
      inherit (pkgsRelease) firefox-unwrapped;
    };
}
