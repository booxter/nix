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

          prxStateVersion = "25.11";
          prxNetIface = "enp5s0f0np0";
          prxPassword = "$6$CfXpVD4RDVuPrP1r$sQ8DQgErhyPNmVsRB0cJPwiF/UM3yFC2ZTYRCdtrBAYQXG63GlnLIyOc5vZ2jswJb66KGwitwErNXmUnBWy0R.";

          piStateVersion = "25.11";
          piHostname = "pi5";

          nvws = "nvws";
          proxmox = "proxmox";

          toVmName = name: "${name}vm";

          VM =
            args@{
              name,
              stateVersion ? "25.11",
              ...
            }:
            let
              vmname = toVmName name;
              localName = "local-${vmname}";
              proxName = "prox-${vmname}";
            in
            {
              "${localName}" = helper.mkVM (
                args
                // {
                  inherit stateVersion virtPlatform;
                  platform = "aarch64-linux";
                  hostname = localName;
                }
              );

              "${proxName}" = helper.mkVM (
                args
                // {
                  inherit stateVersion virtPlatform;
                  platform = "x86_64-linux";
                  hostname = proxName;
                }
              );
            };
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

          # TODO: can I use mkVM here?
          ${toVmName proxmox} = helper.mkProxmox {
            inherit username virtPlatform;
            stateVersion = prxStateVersion;
            hostname = toVmName proxmox;
            netIface = "eth0";
            ipAddress = toVmName proxmox;
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

          # TODO: automatically sync ip-mac mapping with dhcp config
          ${nvws} = helper.mkProxmox {
            inherit username;
            password = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
            stateVersion = "25.11";
            netIface = "enp3s0f0";
            hostname = nvws;
            ipAddress = "192.168.15.100";
            macAddress = "ac:b4:80:40:05:2e";
          };

          "prx1-lab" = helper.mkProxmox {
            inherit username;
            password = prxPassword;
            stateVersion = prxStateVersion;
            netIface = prxNetIface;
            hostname = "prx1-lab";
            ipAddress = "192.168.15.10";
            macAddress = "38:05:25:30:7d:89";
          };

          "prx2-lab" = helper.mkProxmox {
            inherit username;
            password = prxPassword;
            stateVersion = prxStateVersion;
            netIface = prxNetIface;
            hostname = "prx2-lab";
            ipAddress = "192.168.15.11";
            macAddress = "38:05:25:30:7f:7d";
          };

          "prx3-lab" = helper.mkProxmox {
            inherit username;
            password = prxPassword;
            stateVersion = prxStateVersion;
            netIface = prxNetIface;
            hostname = "prx3-lab";
            ipAddress = "192.168.15.12";
            macAddress = "38:05:25:30:7d:69";
          };
        }
        # TODO: calculate stable ssh port numbers based on hostnames, somehow
        # TODO: then, configure ssh config aliases for each of them
        // VM {
          name = "nv";
          isWork = true;
          cores = 64;
          memorySize = 64;
          diskSize = 100;
          sshPort = 10000;

          extraModules = [
            (
              { ... }:
              {
                # Enable flags needed for DPDK (hugepages, SS*E...)
                virtualisation.proxmox = {
                  args = "-cpu kvm64,+ssse3,+sse4_1,+sse4_2,+pdpe1gb";
                };
                boot.kernelParams = [
                  "default_hugepagesz=1GB"
                  "hugepagesz=1G"
                  "hugepages=8"
                  "hugepagesz=2M"
                  "hugepages=512"
                ];
              }
            )
          ];
        }
        // VM {
          name = "linux";
          sshPort = 10001;
        }
        // VM {
          name = piHostname;
          stateVersion = piStateVersion;
        };

      overlays = import ./overlays { inherit inputs; };
      packages = helper.forAllSystems (system: import ./pkgs inputs.nixpkgs.legacyPackages.${system});
      formatter = helper.forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
