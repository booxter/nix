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
    #proxmox-nixos.url = "github:booxter/proxmox-nixos/crypt-perl";

    disko.url = "github:nix-community/disko/latest";

    nixpkgs-netbootxyz.url = "github:booxter/nixpkgs/netbootxyz-update";
  };

  outputs =
    inputs@{ self, ... }:
    let
      inherit (self) outputs;
      username = "ihrachyshka";
      helper = import ./lib { inherit inputs outputs username; };
    in
    {
      homeConfigurations = {
        # nv dev env
        "${username}@nv" = helper.mkHome {
          stateVersion = "25.11";
          platform = "x86_64-linux";
          isWork = true;
        };
      };

      darwinConfigurations = {
        mair = helper.mkDarwin {
          stateVersion = 6;
          hmStateVersion = "25.11";
          hostname = "mair";
          platform = "aarch64-darwin";
          isDesktop = true;
        };
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

      nixosConfigurations =
        let
          virtPlatform = "aarch64-darwin";
          vmPlatform = "aarch64-linux";

          proxmoxStateVersion = "25.11";

          piStateVersion = "25.11";
          piHostname = "pi5";

          linux = "linux";
          nv = "nv";
          proxmox = "proxmox";

          toVmName = name: "${name}vm";
        in
        {
          pi5 = helper.mkRaspberryPi {
            hostname = piHostname;
            stateVersion = piStateVersion;
            extraModules = [
              (
                { ... }:
                {
                  users.users.${username} = {
                    hashedPassword = "$6$cgM30pIRZnRi0o21$qMkHs50CF.4Af4UWT.l/INY2nq3zAValESyaWj6mi.cvROO7cOjNXdttwCaEyQMaQAGzRlUJkkmJHUd.DFNxY0";
                  };
                }
              )
            ];
          };

          ${toVmName piHostname} = helper.mkNixos {
            inherit virtPlatform;
            stateVersion = piStateVersion;
            hostname = piHostname; # use the same hostname to retain config
            platform = vmPlatform;
            isVM = true;
          };

          ${toVmName linux} = helper.mkNixos {
            inherit virtPlatform;
            stateVersion = "25.11";
            hostname = toVmName linux;
            platform = vmPlatform;
            isVM = true;
            # TODO: calculate stable port numbers based on hostnames, somehow
            # TODO: then, configure ssh config aliases for each of them
            sshPort = 10000;

            extraModules = [
              (
                { ... }:
                {
                  virtualisation.vmVariant.virtualisation = {
                    cores = 4;
                    memorySize = 4 * 1024; # 4GB
                  };
                }
              )
            ];
          };

          ${toVmName nv} = helper.mkNixos {
            inherit virtPlatform;
            stateVersion = "25.11";
            hostname = toVmName nv;
            platform = vmPlatform;
            isVM = true;
            sshPort = 10001;

            isWork = true;

            extraModules = [
              (
                { ... }:
                {
                  virtualisation.vmVariant.virtualisation = {
                    cores = 8;
                    memorySize = 16 * 1024; # 16GB
                    diskSize = 100 * 1024; # 100GB
                  };
                }
              )
            ];
          };

          prx1-lab = helper.mkProxmox {
            stateVersion = proxmoxStateVersion;
            hostname = "prx1-lab";
          };

          ${toVmName proxmox} = helper.mkProxmox {
            inherit virtPlatform;
            stateVersion = proxmoxStateVersion;
            hostname = toVmName proxmox;
            isVM = true;
            sshPort = 10002;

            isWork = true;

            extraModules = [
              (
                { ... }:
                {
                  virtualisation.vmVariant.virtualisation = {
                    cores = 8;
                    memorySize = 16 * 1024; # 16GB
                    diskSize = 100 * 1024; # 100GB

                    forwardPorts =
                      let
                        proxmoxPort = 8006;
                      in
                      [
                        {
                          from = "host";
                          guest.port = proxmoxPort;
                          host.port = proxmoxPort;
                        }
                      ];
                  };
                }
              )
            ];
          };
        };

      overlays = import ./overlays { inherit inputs; };
      packages = helper.forAllSystems (system: import ./pkgs inputs.nixpkgs.legacyPackages.${system});
      formatter = helper.forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
