# Inspirations:
# - https://github.com/wimpysworld/nix-config/ for general structure
{
  description = "booxter Nix* flake configs";

  inputs = {
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    homebrew-core = {
      url = "github:homebrew/homebrew-core";
      flake = false;
    };
    homebrew-cask = {
      url = "github:homebrew/homebrew-cask";
      flake = false;
    };

    home-manager.url = "github:nix-community/home-manager/master";
    nixvim.url = "github:nix-community/nixvim";
    nur.url = "github:nix-community/NUR";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    nixpkgs-netbootxyz.url = "github:booxter/nixpkgs/netbootxyz-update";
  };

  outputs = inputs@{ self, ... }:
  let
    inherit (self) outputs;
    username = "ihrachyshka";
    helper = import ./lib { inherit inputs outputs username; };
  in
  {
    homeConfigurations = {
      # personal mac mini
      "${username}@mmini" = helper.mkHome {
        stateVersion = "25.11";
        platform = "aarch64-darwin";
        isDesktop = true;
      };
      # nv laptop
      "${username}@ihrachyshka-mlt" = helper.mkHome {
        stateVersion = "25.11";
        platform = "aarch64-darwin";
        isDesktop = true;
        isWork = true;
      };
      # nv dev env
      "${username}@nv" = helper.mkHome {
        stateVersion = "25.11";
        platform = "x86_64-linux";
        isWork = true;
      };
    };

    darwinConfigurations = {
      mmini = helper.mkDarwin {
        stateVersion = 5;
        hmStateVersion = "25.11";
        hostname = "mmini";
        platform = "aarch64-darwin";
        isDesktop = true;
      };
      ihrachyshka-mlt = helper.mkDarwin {
        stateVersion = 5;
        hmStateVersion = "25.11";
        hostname = "ihrachyshka-mlt";
        platform = "aarch64-darwin";
        isDesktop = true;
        isWork = true;
      };
    };

    nixosConfigurations = {
      pi5 = helper.mkRaspberryPi {
        hostname = "pi5";
        stateVersion = "25.11";

        extraModules = [
          ({ pkgs, ... }: {
            nixpkgs.hostPlatform = inputs.nixpkgs.lib.mkDefault "aarch64-linux";
          })
        ];
      };

      linuxVM = helper.mkNixos {
        stateVersion = "25.11";
        hostname = "linuxvm";
        platform = "aarch64-linux";
        virtPlatform = "aarch64-darwin";

        isVM = true;
        sshPort = 10000;

        extraModules = [
          ({ ... }: {
            virtualisation.vmVariant.virtualisation = {
              cores = 4;
              memorySize = 4 * 1024; # 4GB
            };
          })
        ];
      };

      nVM = helper.mkNixos {
        stateVersion = "25.11";
        hostname = "nvm";
        platform = "aarch64-linux";
        virtPlatform = "aarch64-darwin";

        isWork = true;
        isVM = true;
        sshPort = 10001;

        extraModules = [
          ({ ... }: {
            virtualisation.vmVariant.virtualisation = {
              cores = 8;
              memorySize = 16 * 1024; # 16GB
              diskSize = 100 * 1024; # 100GB
            };
          })
        ];
      };
    };

    linuxVM = self.nixosConfigurations.linuxVM.config.system.build.vm;
    nVM = self.nixosConfigurations.nVM.config.system.build.vm;

    overlays = import ./overlays { inherit inputs; };
    packages = helper.forAllSystems (system: import ./pkgs inputs.nixpkgs.legacyPackages.${system});
    formatter = helper.forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
  };
}
