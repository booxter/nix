# Inspirations:
# - https://github.com/wimpysworld/nix-config/ for general structure
{
  description = "booxter Nix* flake configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    # Use staging-next if needed
    #nixpkgs-staging-next.url = "github:NixOS/nixpkgs/staging-next";
    #nixpkgs = nixpkgs-staging-next;

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

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
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    proxmox-nixos.url = "github:booxter/proxmox-nixos/my-fork";

    disko.url = "github:nix-community/disko/latest";

    debugserver.url = "github:reckenrode/nixpkgs/push-tnkmrvyqmzpu";

    nixpkgs-nut.url = "github:booxter/nixpkgs/nut-darwin";

    # TODO: switch to official when diff is contributed upstream
    jellarr.url = "github:booxter/jellarr/my-fork-plus-fix-plugin-404";
    #jellarr.url = "github:venkyr77/jellarr/v0.1.0";
    jellarr.inputs.nixpkgs.follows = "nixpkgs";

    nixarr.url = "github:rasmus-kirk/nixarr";
    nixarr.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ self, ... }:
    let
      inherit (self) outputs;
      username = "ihrachyshka";
      helpers = import ./lib { inherit inputs outputs username; };

      darwinHosts = {
        mair = {
          stateVersion = 6;
          hmStateVersion = "25.11";
          hostname = "mair";
          platform = "aarch64-darwin";
          isDesktop = true;
        };
        mmini = {
          stateVersion = 5;
          hmStateVersion = "25.11";
          hostname = "mmini";
          platform = "aarch64-darwin";
          isDesktop = true;
        };
        JGWXHWDL4X = {
          stateVersion = 5;
          hmStateVersion = "25.11";
          hostname = "JGWXHWDL4X";
          platform = "aarch64-darwin";
          isDesktop = true;
          isWork = true;
        };
      };
    in
    {
      homeConfigurations = {
        # nv dev env
        "${username}@nv" = helpers.mkHome {
          stateVersion = "25.11";
          platform = "x86_64-linux";
          isWork = true;
        };
      };

      darwinConfigurations =
        let
          base = builtins.listToAttrs (
            map (
              name:
              let
                cfg = darwinHosts.${name};
              in
              {
                name = name;
                value = helpers.mkDarwin cfg;
              }
            ) (builtins.attrNames darwinHosts)
          );
          ciVariants = builtins.listToAttrs (
            map (
              name:
              let
                cfg = darwinHosts.${name} // {
                  ci = true;
                };
              in
              {
                name = "${name}-ci";
                value = helpers.mkDarwin cfg;
              }
            ) (builtins.attrNames darwinHosts)
          );
        in
        base // ciVariants;

      nixosConfigurations =
        let
          virtPlatform = "aarch64-darwin";

          prxStateVersion = "25.11";
          prxNetIface = "enp5s0f0np0";
          prxPassword = "$6$CfXpVD4RDVuPrP1r$sQ8DQgErhyPNmVsRB0cJPwiF/UM3yFC2ZTYRCdtrBAYQXG63GlnLIyOc5vZ2jswJb66KGwitwErNXmUnBWy0R.";

          piStateVersion = "25.11";
          piHostname = "pi5";

          frame = "frame";
          nvws = "nvws";

          toVmName = name: "${name}vm";

          VM =
            args@{
              name,
              stateVersion ? "25.11",
              platform ? "aarch64-linux",
              ...
            }:
            let
              vmname = toVmName name;
              localName = "local-${vmname}";
              proxName = "prox-${vmname}";
              ciName = "ci-${vmname}";
            in
            {
              "${localName}" = helpers.mkVM (
                args
                // {
                  inherit platform stateVersion virtPlatform;
                  hostname = localName;
                }
              );

              "${ciName}" = helpers.mkVM (
                args
                // {
                  inherit stateVersion;
                  hostname = ciName;
                  platform = "x86_64-linux";
                  virtPlatform = "x86_64-linux";
                }
              );

              "${proxName}" = helpers.mkVM (
                args
                // {
                  inherit stateVersion virtPlatform;
                  hostname = proxName;
                  platform = "x86_64-linux";
                }
              );
            };
          toBuilder =
            idx:
            VM (
              let
                idx' = toString idx;
              in
              {
                name = "builder${idx'}";
                proxNode = "prx${idx'}-lab";
                stateVersion = "25.11";
                memorySize = 64;
                diskSize = 300;
                cores = 24;
                withHome = false;
              }
            );
        in
        {
          pi5 = helpers.mkRaspberryPi {
            hostname = piHostname;
            stateVersion = piStateVersion;
          };

          ${frame} = helpers.mkNixos {
            password = "$6$yJXP9KwAM7LaQrtn$K5ybpfl1xxjRTRMXj6CxSFspEdDcWeEVzhc6Wq0PX7G/y9Tvt1QWq5F6ycR0wy4TseTXeom9DdzK4XrBwym2Q/";
            hostname = frame;
            stateVersion = "25.11";
            platform = "x86_64-linux";
            isDesktop = true;
          };

          # TODO: automatically sync ip-mac mapping with dhcp config
          ${nvws} = helpers.mkProxmox {
            inherit username;
            isWork = true;
            password = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
            stateVersion = "25.11";
            netIface = "enp3s0f0";
            hostname = nvws;
            ipAddress = "192.168.15.100";
            macAddress = "ac:b4:80:40:05:2e";
          };

          # ssh prx1-lab sudo pvecm create lab-cluster
          "prx1-lab" = helpers.mkProxmox {
            inherit username;
            password = prxPassword;
            stateVersion = prxStateVersion;
            netIface = prxNetIface;
            hostname = "prx1-lab";
            ipAddress = "192.168.15.10";
            macAddress = "38:05:25:30:7d:89";
          };

          # ssh prx2-lab sudo pvecm add prx1-lab
          "prx2-lab" = helpers.mkProxmox {
            inherit username;
            password = prxPassword;
            stateVersion = prxStateVersion;
            netIface = prxNetIface;
            hostname = "prx2-lab";
            ipAddress = "192.168.15.11";
            macAddress = "38:05:25:30:7f:7d";
          };

          # ssh prx3-lab sudo pvecm add prx1-lab
          "prx3-lab" = helpers.mkProxmox {
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
          memorySize = 128;
          sshPort = 10000;
          proxNode = "nvws";
        }
        // VM {
          name = "linux";
          sshPort = 10001;
        }
        // VM {
          name = "linuxui";
          sshPort = 10002;
          memorySize = 8;
          withHome = false;
        }
        // VM {
          name = "jellyfin";
          platform = "x86_64-linux";
          cores = 20;
          memorySize = 32;
          sshPort = 10003;
          withHome = false;
        }
        // VM {
          name = "cache";
          sshPort = 10004;
          withHome = false;
          cores = 16;
          memorySize = 16;
          diskSize = 50; # actual cache is on NFS
        }
        // VM {
          name = "srvarr";
          platform = "x86_64-linux";
          cores = 16;
          memorySize = 32;
          sshPort = 10005;
          withHome = false;
        }
        // toBuilder 1
        // toBuilder 2
        // toBuilder 3;

      devShells = helpers.forAllSystems (
        system:
        let
          pkgs = import inputs.nixpkgs { inherit system; };
        in
        {
          air-sdk = pkgs.mkShell {
            buildInputs = with pkgs; [
              python3
              outputs.packages.${system}.air-sdk
            ];
          };
        }
      );

      overlays = import ./overlays { inherit inputs; };
      packages = helpers.forAllSystems (system: import ./pkgs inputs.nixpkgs.legacyPackages.${system});
      formatter = helpers.forAllSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "formatter";
          runtimeInputs = with pkgs; [
            nixfmt-tree
            shellcheck
            mbake
          ];
          text = ''
            treefmt "$@"
            mbake format Makefile
            find . -type f -name '*.sh' -exec shellcheck {} +
          '';
        }
      );
    };
}
