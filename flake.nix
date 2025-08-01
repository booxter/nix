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

    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos";

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

    nixosConfigurations = let
      virtPlatform = "aarch64-darwin";
      targetPlatform = "aarch64-linux";

      pi-stateVersion = "25.11";
      pi-hostname = "pi5";

      linux = "linux";
      nv = "nv";
      proxmox = "proxmox";

      toVmName = name: "${name}vm";
    in {
      pi5 = helper.mkRaspberryPi {
        hostname = pi-hostname;
        stateVersion = pi-stateVersion;
      };

      ${toVmName pi-hostname} = helper.mkNixos {
        inherit virtPlatform;
        stateVersion = pi-stateVersion;
        hostname = pi-hostname; # use the same hostname to retain config
        platform = targetPlatform;
        isVM = true;
      };

      ${toVmName linux} = helper.mkNixos {
        inherit virtPlatform;
        stateVersion = "25.11";
        hostname = toVmName linux;
        platform = targetPlatform;
        isVM = true;
        # TODO: calculate stable port numbers based on hostnames, somehow
        # TODO: then, configure ssh config aliases for each of them
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

      ${toVmName nv} = helper.mkNixos {
        inherit virtPlatform;
        stateVersion = "25.11";
        hostname = toVmName nv;
        platform = targetPlatform;
        isVM = true;
        sshPort = 10001;

        isWork = true;

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

      ${toVmName proxmox} = let
        system = "x86_64-linux"; # will eventually run on x86_64 hosts
      in helper.mkProxmox {
        inherit virtPlatform;
        stateVersion = "25.11";
        hostname = toVmName proxmox;
        platform = system; 
        isVM = true;
        sshPort = 10002;

        isWork = true;

        extraModules = [
          ({ ... }: {
            virtualisation.vmVariant.virtualisation = {
              cores = 8;
              memorySize = 16 * 1024; # 16GB
              diskSize = 100 * 1024; # 100GB
            };
          })

          ({ ... }: {
            services.proxmox-ve.ipAddress = "192.168.0.1";
          })

          ({ ... }: {
            virtualisation.vmVariant.virtualisation.forwardPorts = let
              proxmoxPort = 8006;
            in [
              {
                from = "host";
                guest.port = proxmoxPort;
                host.port = proxmoxPort;
              }
            ];
          })
        ];
      };
    };

    overlays = import ./overlays { inherit inputs; };
    packages = helper.forAllSystems (system: import ./pkgs inputs.nixpkgs.legacyPackages.${system});
    formatter = helper.forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
  };
}
