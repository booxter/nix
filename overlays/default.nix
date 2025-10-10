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
      pkgsMaster = getPkgs inputs.nixpkgs-master;
      pkgsKrunkit = getPkgs inputs.nixpkgs-krunkit;
      pkgsLldb = getPkgs inputs.debugserver;
      pkgsNokogiri = getPkgs inputs.nixpkgs-ruby-nokogiri;
      pkgsGtk3 = getPkgs inputs.nixpkgs-gtk3;
    in
    {
      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      inherit (pkgs) netbootxyz-efi;

      inherit (pkgsNokogiri) defaultGemConfig;

      inherit (pkgsGtk3) gtk3;

      # https://github.com/NixOS/nixpkgs/pull/449614
      inherit (pkgsMaster) dotnetCorePackages;

      podman = pkgs.podman.override {
        extraPackages = _final.lib.optionals _final.stdenv.hostPlatform.isDarwin [
          pkgsKrunkit.krunkit
        ];
      };

      ramalama = pkgs.ramalama.override { podman = _final.podman; };
    };
}
