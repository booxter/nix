# Inspirations:
# - https://github.com/wimpysworld/nix-config/ for general structure
{
  description = "booxter Nix* flake configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-master.url = "github:NixOS/nixpkgs/master";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    #nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.url = "github:booxter/nix-darwin/dhcp-client";
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

    proxmox-nixos.url = "github:booxter/proxmox-nixos/my-fork";

    disko.url = "github:nix-community/disko/latest";

    debugserver.url = "github:reckenrode/nixpkgs/push-tnkmrvyqmzpu";

    # https://github.com/NixOS/nixpkgs/pull/417062
    nixpkgs-krunkit.url = "github:quinneden/nixpkgs/init-libkrun-efi-and-krunkit";

    randy-config.url = "github:reckenrode/nixos-configs";

    declarative-jellyfin.url = "github:Sveske-Juice/declarative-jellyfin";

    attic.url = "github:zhaofengli/attic";
  };

  outputs =
    inputs@{ self, ... }:
    let
      inherit (self) outputs;
      username = "ihrachyshka";
      helpers = import ./lib { inherit inputs outputs username; };
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

      darwinConfigurations = {
        mair = helpers.mkDarwin {
          stateVersion = 6;
          hmStateVersion = "25.11";
          hostname = "mair";
          platform = "aarch64-darwin";
          isDesktop = true;
        };
        mmini = helpers.mkDarwin {
          stateVersion = 5;
          hmStateVersion = "25.11";
          hostname = "mmini";
          platform = "aarch64-darwin";
          isDesktop = true;
        };
        ihrachyshka-mlt = helpers.mkDarwin {
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

          frame = "frame";
          nvws = "nvws";
          proxmox = "proxmox";

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
            in
            {
              "${localName}" = helpers.mkVM (
                args
                // {
                  inherit platform stateVersion virtPlatform;
                  hostname = localName;
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
                memorySize = 32;
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
            # TODO: add password argument to the helpers like in nixos helpers; use it
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

          ${frame} = helpers.mkNixos {
            password = "$6$yJXP9KwAM7LaQrtn$K5ybpfl1xxjRTRMXj6CxSFspEdDcWeEVzhc6Wq0PX7G/y9Tvt1QWq5F6ycR0wy4TseTXeom9DdzK4XrBwym2Q/";
            hostname = frame;
            stateVersion = "25.11";
            platform = "x86_64-linux";
            isDesktop = true;
          };

          # TODO: can I use mkVM here?
          ${toVmName proxmox} = helpers.mkProxmox {
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
          ${nvws} = helpers.mkProxmox {
            inherit username;
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
          memorySize = 64;
          sshPort = 10000;
          proxNode = "nvws";

          extraModules = [
            (
              { ... }:
              {
                boot.kernelParams = [
                  "default_hugepagesz=1GB"
                  "hugepagesz=1G"
                  "hugepages=8"
                  "hugepagesz=2M"
                  "hugepages=6000"
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
          name = "linuxui";
          sshPort = 10002;
          memorySize = 8;
          withHome = false;

          extraModules = [
            (
              { lib, pkgs, ... }:
              {
                services.xserver.enable = true;
                services.xserver.displayManager.gdm.enable = true;
                programs.hyprland = {
                  enable = true;
                  xwayland.enable = true;
                };

                environment.systemPackages = with pkgs; [
                  kitty
                  podman-desktop
                ];

                virtualisation.vmVariant.virtualisation = {
                  graphics = lib.mkForce true;
                };

                users.users.${username} = {
                  password = "testpass";
                };
              }
            )
          ];
        }
        // VM {
          name = "jellyfin";
          platform = "x86_64-linux";
          cores = 16;
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
          name = piHostname;
          stateVersion = piStateVersion;
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
      formatter = helpers.forAllSystems (system: inputs.nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
