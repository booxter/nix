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
      pkgsJF = getPkgs inputs.jellyfin-pinned;
    in
    {
      # https://github.com/NixOS/nixpkgs/pull/374846
      inherit (pkgsLldb) debugserver;

      inherit (pkgs) netbootxyz-efi;

      inherit (pkgsJF) jellyfin jellyfin-web;

      whisparr = prev.whisparr.overrideAttrs (old: rec {
        pname = "whisparr";
        version = "3.0.2.1433";
        src = prev.fetchurl {
          name = "${pname}-x86-linux-${version}.tar.gz";
          url = "https://whisparr.servarr.com/v1/update/eros/updatefile?runtime=netcore&version=${version}&arch=x64&os=linux";
          hash = "sha256-uIkKdkqRSnDlH2+z16blRdhZW8n7doFXN1U1tfG1K3c=";
        };
        passthru =
          old.passthru
          // {
            inherit version;
          };
      });

      podman = pkgs.podman.override {
        extraPackages = _final.lib.optionals _final.stdenv.hostPlatform.isDarwin [
          pkgs.krunkit
        ];
      };

      ramalama = pkgs.ramalama.override { podman = _final.podman; };
    };
}
