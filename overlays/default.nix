{ inputs, ... }:
{
  # This one brings our custom packages from the 'pkgs' directory
  additions = final: _prev: import ../pkgs final.pkgs;

  # This one contains whatever you want to overlay
  # You can change versions, add patches, set compilation flags, anything really.
  # https://nixos.wiki/wiki/Overlays
  modifications =
    _final: prev:
    let
      moltenvk = ((import inputs.nixpkgs { inherit (prev) system; }).moltenvk).overrideAttrs (oldAttrs: {
        patches = [
          (_final.fetchpatch {
            url = "https://github.com/KhronosGroup/MoltenVK/pull/2441/commits/70a3a152168bb8aefd1553e57ca165a590b77a06.patch";
            hash = "sha256-7yyq/6H0/4m0zlu2f9XKkxKGISCW4suQLRxcLlmyWXQ=";
          })
          ./0001-MVKShaderLibrary-Handle-specializtion-with-macros.patch
          (_final.fetchpatch {
            url = "https://github.com/KhronosGroup/MoltenVK/commit/856c8237ac3b32178caae3408effc35bedfdffa1.patch";
            hash = "sha256-+8027qyCKq4NNaca8jNZesAhFHs/piO32KoLKoff2D8=";
          })
        ];

      });

    in
    {
      # newer netboot
      inherit (import inputs.nixpkgs-netbootxyz { inherit (prev) system; }) netbootxyz-efi;

      nixpkgs-review = (import inputs.nixpkgs { inherit (prev) system; }).nixpkgs-review.override {
        withNom = true;
      };

      # https://github.com/NixOS/nixpkgs/pull/432677
      inherit (import inputs.nixpkgs-master { inherit (prev) system; }) ghostty-bin;

      # https://github.com/NixOS/nixpkgs/pull/417062
      inherit (import inputs.nixpkgs-krunkit { inherit (prev) system; }) libkrun-efi;
      krunkit =
        ((import inputs.nixpkgs-krunkit { inherit (prev) system; }).krunkit.override {
          libkrun-efi =
            (_final.libkrun-efi.override {
              inherit moltenvk;
              withGpu = true;
            }).overrideAttrs
              (oldAttrs: rec {
                version = "1.14.0";
                src = _final.fetchFromGitHub {
                  owner = "containers";
                  repo = "libkrun";
                  tag = "v${version}";
                  hash = "sha256-tXF1AkcwSBj+e3qEGR/NqB1U+y4+MIRbaL9xB0cZQbQ=";
                };
                cargoDeps = _final.rustPlatform.fetchCargoVendor {
                  inherit src;
                  hash = "sha256-IrJVP7I8NDB4KyZ0g8D6Tx+dT+lN8Yg8uRT9tXlL/8s=";
                };
              });
        }).overrideAttrs
          (oldAttrs: rec {
            version = "0.2.2";
            src = _final.fetchFromGitHub {
              owner = "containers";
              repo = "krunkit";
              tag = "v${version}";
              hash = "sha256-fyk3vF/d+qv347XI1+z7zzd5JxRRjopnKIV6GATA3Ac=";
            };
            cargoDeps = _final.rustPlatform.fetchCargoVendor {
              inherit src;
              hash = "sha256-4WLmIlk2OSmIt9FPDjCPHD5JyBszCWMwVEhbnnKKNQY=";
            };
          });

      podman = prev.podman.override {
        extraPackages = [
          _final.krunkit
        ];
      };

      ramalama =
        let
          vulkan-loader = (import inputs.nixpkgs { inherit (prev) system; }).vulkan-loader.override {
            inherit moltenvk;
          };
          llama-cpp = (import inputs.nixpkgs { inherit (prev) system; }).llama-cpp.override {
            inherit vulkan-loader;
          };
          llama-cpp-vulkan = (import inputs.nixpkgs { inherit (prev) system; }).llama-cpp-vulkan.override {
            inherit llama-cpp;
          };

        in
        ((import inputs.nixpkgs-master { inherit (prev) system; }).ramalama.override {
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
                  lib.makeBinPath [
                    _final.podman
                    llama-cpp-vulkan
                    _final.python313Packages.mlx-lm
                    _final.python313Packages.huggingface-hub
                  ]
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

  # When applied, the unstable nixpkgs set (declared in the flake inputs) will
  # be accessible through 'pkgs.unstable'
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final) system;
      config.allowUnfree = true;
    };
  };

  master-packages = final: _prev: {
    master = import inputs.nixpkgs-master {
      inherit (final) system;
      config.allowUnfree = true;
    };
  };
}
