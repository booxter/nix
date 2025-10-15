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
    in
    {
      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      inherit (pkgs) netbootxyz-efi;

      podman = pkgs.podman.override {
        extraPackages = _final.lib.optionals _final.stdenv.hostPlatform.isDarwin [
          pkgsKrunkit.krunkit
        ];
      };

      ramalama = pkgs.ramalama.override { podman = _final.podman; };
    };
}
