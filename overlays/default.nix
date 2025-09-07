{ inputs, ... }:
{
  additions = final: _prev: import ../pkgs final.pkgs;

  modifications = _final: prev: {
    # newer netboot: https://github.com/NixOS/nixpkgs/pull/428898
    inherit (import inputs.nixpkgs-master { inherit (prev) system; }) netbootxyz-efi;

    # pull build fix from master: https://github.com/NixOS/nixpkgs/pull/439995
    podman = (import inputs.nixpkgs-master { inherit (prev) system; }).podman.override {
      extraPackages = _final.lib.optionals _final.stdenv.hostPlatform.isDarwin [
        ((import inputs.nixpkgs-krunkit { inherit (prev) system; }).krunkit.override {
          libkrun-efi = (import inputs.nixpkgs-krunkit { inherit (prev) system; }).libkrun-efi.override {
            inherit (import inputs.nixpkgs-moltenvk { inherit (prev) system; }) moltenvk;
          };
        })
      ];
    };

    ramalama =
      let
        vulkan-loader = (import inputs.nixpkgs { inherit (prev) system; }).vulkan-loader.override {
          inherit (import inputs.nixpkgs-moltenvk { inherit (prev) system; }) moltenvk;
        };
        llama-cpp = (import inputs.nixpkgs { inherit (prev) system; }).llama-cpp.override {
          inherit vulkan-loader;
        };
        llama-cpp-vulkan = (import inputs.nixpkgs { inherit (prev) system; }).llama-cpp-vulkan.override {
          inherit llama-cpp;
        };

      in
      # master has a fix for flaky test: https://github.com/NixOS/nixpkgs/pull/439758
      ((import inputs.nixpkgs-master { inherit (prev) system; }).ramalama.override {
        llama-cpp = llama-cpp-vulkan;
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

    pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      (python-final: python-prev: {
        # https://github.com/NixOS/nixpkgs/pull/439354
        inherit ((import inputs.nixpkgs-master { inherit (prev) system; }).python3Packages) lm-eval;
      })
    ];
  };
}
