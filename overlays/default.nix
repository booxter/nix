{ inputs, ... }:
{
  # This one brings our custom packages from the 'pkgs' directory
  additions = final: _prev: import ../pkgs final.pkgs;

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications = _final: prev: {
    # newer netboot
    inherit (import inputs.nixpkgs-netbootxyz { inherit (prev) system; }) netbootxyz-efi;

    podman = prev.podman.override {
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
      # pull from master for 0.21.1 (contains chat template parsing fix)
      ((import inputs.nixpkgs-master { inherit (prev) system; }).ramalama.override {
        podman = _final.podman;
      }).overrideAttrs
        (oldAttrs: {
          patches = [
            # chat template fix for models from ollama registry:
            # https://github.com/containers/ramalama/pull/1890
            (_final.fetchpatch {
              url = "https://github.com/containers/ramalama/pull/1890/commits/950bf1127f2383b39e70200fbbcfcdd4f2a77b9d.patch";
              hash = "sha256-7vaA3g6tX2v9FEDVQl2NkCa4LBUJthTA0Linc1aWyd8=";
            })
            # Suppress llama.cpp output when --nocontainer used:
            # https://github.com/containers/ramalama/pull/1880
            (_final.fetchpatch {
              url = "https://github.com/containers/ramalama/pull/1880/commits/30ff539ac57cefeb419ea4a7fa6ec5229f0feafa.patch";
              hash = "sha256-OZPl1m9r911IyaIdxfMsY4Rjy49/Pk8/XT/xa+zhBSA=";
            })
          ];
          # flaky test due to access to /tmp/ramalama/store:
          # https://github.com/NixOS/nixpkgs/pull/439758/
          disabledTests = [
            "test_ollama_model_pull"
          ];
          postInstall =
            let
              lib = _final.lib;
            in
            ''
              wrapProgram $out/bin/ramalama \
              --prefix PATH : ${
                lib.makeBinPath (
                  [
                    _final.podman
                    llama-cpp-vulkan
                    _final.python313Packages.huggingface-hub
                  ]
                  ++ lib.optional (lib.meta.availableOn _final.stdenv.hostPlatform _final.python313Packages.mlx-lm) _final.python313Packages.mlx-lm
                )
              }
            '';
        });

    # python312 = prev.python312.override {
    #   packageOverrides = final: prev: {
    #     XXX = prev.XXX.overridePythonAttrs (oldAttrs: {
    #       disabledTests = oldAttrs.disabledTests ++ [
    #       ];
    #     });
    #   };
    # };
    # python312Packages = python312.pkgs;
  };
}
