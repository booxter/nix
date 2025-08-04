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

          numProxmoxNodes = 3;
          prxStateVersion = "25.11";

          piStateVersion = "25.11";
          piHostname = "pi5";

          linux = "linux";
          nv = "nv";
          nvws = "nvws";
          proxmox = "proxmox";

          toVmName = name: "${name}vm";
        in
        {
          pi5 = helper.mkRaspberryPi {
            hostname = piHostname;
            stateVersion = piStateVersion;
            # TODO: add password argument to the helper like in nixos helper; use it
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
            isWork = true;
            isVM = true;
            sshPort = 10001;

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

          ${toVmName proxmox} =
            let
              name = toVmName proxmox;
            in
            helper.mkProxmox {
              inherit username virtPlatform;
              stateVersion = prxStateVersion;
              hostname = name;
              netIface = "eth0";
              ipAddress = name;
              isWork = true;
              isVM = true;
              sshPort = 10002;

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

          ${nvws} = helper.mkProxmox {
            inherit username;
            password = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
            stateVersion = "25.11";
            hostname = nvws;
            netIface = "enp3s0f0";
            # TODO: automatically sync with dhcp config
            ipAddress = "192.168.15.100";
          };
        }
        // (inputs.nixpkgs.lib.genAttrs
          (map (n: "prx${toString n}-lab") (inputs.nixpkgs.lib.range 1 numProxmoxNodes))
          (
            name:
            helper.mkProxmox {
              inherit username;
              password = "$6$CfXpVD4RDVuPrP1r$sQ8DQgErhyPNmVsRB0cJPwiF/UM3yFC2ZTYRCdtrBAYQXG63GlnLIyOc5vZ2jswJb66KGwitwErNXmUnBWy0R.";
              stateVersion = prxStateVersion;
              hostname = name;
              netIface = "enp5s0f0np0";
              # TODO: automatically sync with dhcp config
              ipAddress = "192.168.15.${
                toString (
                  9 + inputs.nixpkgs.lib.strings.toInt (builtins.elemAt (builtins.match "prx([0-9]+)-lab" name) 0)
                )
              }";
            }
          )
        );

      overlays = import ./overlays { inherit inputs; };
      packages = helper.forAllSystems (system: import ./pkgs inputs.nixpkgs.legacyPackages.${system});
      formatter = helper.forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
