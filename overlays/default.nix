{ inputs, ... }:
{
  # This one brings our custom packages from the 'pkgs' directory
  additions = final: _prev: import ../pkgs final.pkgs;

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications =
    _final: prev: {
      # newer netboot
      inherit (import inputs.nixpkgs-netbootxyz { inherit (prev) system; }) netbootxyz-efi;

      podman = prev.podman.override {
        extraPackages = _final.lib.optionals _final.stdenv.hostPlatform.isDarwin [
          (import inputs.nixpkgs-krunkit { inherit (prev) system; }).krunkit
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
        ((import inputs.nixpkgs { inherit (prev) system; }).ramalama.override {
          podman = _final.podman;
        }).overrideAttrs
          (oldAttrs: {
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
