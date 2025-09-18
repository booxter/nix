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
    in
    {
      # spotify hash fixed in master: https://github.com/NixOS/nixpkgs/pull/443564
      inherit (pkgsMaster) spotify;

      podman = pkgs.podman.override {
        extraPackages = _final.lib.optionals _final.stdenv.hostPlatform.isDarwin [
          pkgsKrunkit.krunkit
        ];
      };

      ramalama =
        (pkgs.ramalama.override {
          podman = _final.podman;
        }).overrideAttrs
          (oldAttrs: {
            patches = [
              # chat template fix for models from ollama registry:
              # https://github.com/containers/ramalama/pull/1890
              (_final.fetchpatch {
                url = "https://github.com/containers/ramalama/commit/85de59dc415c09f1d2d0046d90a704c08a9a421c.patch";
                hash = "sha256-Elg5gWhtjqZ+kkCpB9SC3mBpxcSw0aJhI0c2AQhvS4g=";
              })
              # Suppress llama.cpp output when --nocontainer used:
              # https://github.com/containers/ramalama/pull/1880
              (_final.fetchpatch {
                url = "https://github.com/containers/ramalama/commit/1ac57e28bf2f63dc0fa4b6c6d97fa60439cfab41.patch";
                hash = "sha256-OZPl1m9r911IyaIdxfMsY4Rjy49/Pk8/XT/xa+zhBSA=";
              })
            ];
          });
    };
}
