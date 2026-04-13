# Inspirations:
# - https://github.com/wimpysworld/nix-config/ for general structure
{
  description = "booxter Nix* flake configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs-25_11.url = "github:NixOS/nixpkgs/release-25.11";
    # Keep Transmission pinned independently from the moving release-25.11 branch.
    # TODO: remove this input when trackers allow 4.1.0+.
    nixpkgs-transmission.url = "github:NixOS/nixpkgs/12d60a4f2d5f2cc96e93ae5615328245d49ac2e8";
    # Temporary diff-so-fancy 1.4.10 backport until it lands in nixpkgs-unstable.
    # TODO: remove this input once nixpkgs includes diff-so-fancy 1.4.10+.
    nixpkgs-diff-so-fancy.url = "github:booxter/nixpkgs/e523d5636f2edfa5688d5fa05b3adc64ef6d9a89";

    # Use staging-next if needed
    #nixpkgs-staging-next.url = "github:NixOS/nixpkgs/staging-next";
    #nixpkgs = nixpkgs-staging-next;

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

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
    home-manager-25_11.url = "github:nix-community/home-manager/release-25.11";
    home-manager-25_11.inputs.nixpkgs.follows = "nixpkgs-25_11";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos/main";

    disko.url = "github:nix-community/disko/latest";

    # Keep Virby's own nixpkgs pin for now to maximize cache hits while bootstrapping
    # the builder image on hosts switching to Virby.
    virby.url = "github:quinneden/virby-nix-darwin/7628dd04c700bf035b54fe7d99e8ced18f097ec6";

    debugserver.url = "github:reckenrode/nixpkgs/push-tnkmrvyqmzpu";

    # TODO: switch to official when diff is contributed upstream
    jellarr.url = "github:booxter/jellarr/my-fork-plus-fix-plugin-404";
    #jellarr.url = "github:venkyr77/jellarr/v0.1.0";
    jellarr.inputs.nixpkgs.follows = "nixpkgs";

    nixarr.url = "github:rasmus-kirk/nixarr";
    nixarr.inputs.nixpkgs.follows = "nixpkgs";

    llm-agents.url = "github:numtide/llm-agents.nix";

    tig = {
      url = "github:jonas/tig";
      flake = false;
    };

    # Pin Darwin Mozilla unwrapped builds while Hydra can time out long-running jobs
    # when no output is produced (missing "silence timer" support). When that
    # happens, build jobs fail and the artifacts are not cached.
    # Building these packages locally/CI is too expensive, so we must stay on
    # the previous cached versions until cache catches up.
    # https://github.com/NixOS/infra/pull/950
    # TODO: remove these inputs when the Hydra issue is fixed.
    nixpkgs-firefox-unwrapped.url = "github:NixOS/nixpkgs/b8197e259ad1b49d63789b7fdb8214644b1b05de";
    nixpkgs-thunderbird-unwrapped.url = "github:NixOS/nixpkgs/eac9adc9cc293c4cec9686f9ae534cf21a5f7c7e";
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
      }
      // builtins.listToAttrs (
        map (
          name:
          let
            cfg = darwinHosts.${name};
          in
          {
            name = "${username}@${name}";
            value = helpers.mkHome {
              stateVersion = cfg.hmStateVersion;
              inherit (cfg)
                platform
                isDesktop
                ;
              isWork = cfg.isWork or false;
            };
          }
        ) (builtins.attrNames darwinHosts)
      );

      darwinConfigurations = builtins.listToAttrs (
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
            in
            {
              "${localName}" = helpers.mkVM (
                args
                // {
                  inherit platform stateVersion virtPlatform;
                  hostname = localName;
                  vmMode = "qemu";
                }
              );

              "${proxName}" = helpers.mkVM (
                args
                // {
                  inherit stateVersion;
                  hostname = proxName;
                  platform = "x86_64-linux";
                  virtPlatform = "x86_64-linux";
                  vmMode = "proxmox";
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
                diskSize = 150;
                cores = 24;
                hmFull = false;
              }
            );
          BM = args: helpers.mkBM ({ inherit virtPlatform; } // args);
        in
        BM {
          mkHost = helpers.mkRaspberryPi;
          name = piHostname;
          stateVersion = piStateVersion;
          homeManagerInput = inputs.home-manager-25_11;
          hmFull = false;
        }
        // BM {
          mkHost = helpers.mkNixos;
          name = frame;
          password = "$6$yJXP9KwAM7LaQrtn$K5ybpfl1xxjRTRMXj6CxSFspEdDcWeEVzhc6Wq0PX7G/y9Tvt1QWq5F6ycR0wy4TseTXeom9DdzK4XrBwym2Q/";
          stateVersion = "25.11";
          platform = "x86_64-linux";
          isDesktop = true;
        }
        # TODO: automatically sync ip-mac mapping with dhcp config
        // BM {
          mkHost = helpers.mkProxmox;
          name = nvws;
          inherit username;
          isWork = true;
          password = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
          stateVersion = "25.11";
          netIface = "enp3s0f0";
          ipAddress = "192.168.15.100";
          macAddress = "ac:b4:80:40:05:2e";
        }
        // BM {
          mkHost = helpers.mkNixos;
          name = "beast";
          stateVersion = "25.11";
          platform = "x86_64-linux";
          nixpkgsInput = inputs.nixpkgs-25_11;
          homeManagerInput = inputs.home-manager-25_11;
          hmFull = false;
        }
        # ssh prx1-lab sudo pvecm create lab-cluster
        // BM {
          mkHost = helpers.mkProxmox;
          name = "prx1-lab";
          inherit username;
          password = prxPassword;
          stateVersion = prxStateVersion;
          netIface = prxNetIface;
          ipAddress = "192.168.15.10";
          macAddress = "38:05:25:30:7d:89";
        }
        # ssh prx2-lab sudo pvecm add prx1-lab
        // BM {
          mkHost = helpers.mkProxmox;
          name = "prx2-lab";
          inherit username;
          password = prxPassword;
          stateVersion = prxStateVersion;
          netIface = prxNetIface;
          ipAddress = "192.168.15.11";
          macAddress = "38:05:25:30:7f:7d";
        }
        # ssh prx3-lab sudo pvecm add prx1-lab
        // BM {
          mkHost = helpers.mkProxmox;
          name = "prx3-lab";
          inherit username;
          password = prxPassword;
          stateVersion = prxStateVersion;
          netIface = prxNetIface;
          ipAddress = "192.168.15.12";
          macAddress = "38:05:25:30:7d:69";
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
          name = "cache";
          sshPort = 10004;
          hmFull = false;
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
          hmFull = false;
        }
        // VM {
          name = "fana";
          platform = "x86_64-linux";
          cores = 8;
          memorySize = 16;
          diskSize = 300;
          sshPort = 10006;
          hmFull = false;
        }
        // VM {
          name = "desk";
          cores = 4;
          memorySize = 12;
          diskSize = 80;
          sshPort = 10007;
          hmFull = false;
        }
        // VM {
          name = "gw";
          cores = 2;
          memorySize = 8;
          diskSize = 64;
          sshPort = 10008;
          hmFull = false;
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

      checks = import ./checks.nix { inherit inputs helpers; };
      nixosTests = import ./nixos-tests.nix { inherit inputs helpers; };

      overlays = import ./overlays { inherit inputs; };
      packages = helpers.forAllSystems (
        system:
        let
          basePackages = import ./pkgs inputs.nixpkgs.legacyPackages.${system};
          fleetPackages = {
            pi-image = self.nixosConfigurations.pi5.config.system.build.sdImage;
            inherit (inputs.disko.packages.${system}) disko-install;
          };
          proxmox = import ./lib/proxmox-apps.nix {
            inherit inputs system;
          };
        in
        basePackages
        // proxmox.packages
        // fleetPackages
        // {
          qemu-host-package = (helpers.mkVmHostPkgs system).qemu;
        }
      );
      apps = helpers.forAllSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          sopsApps = import ./lib/sops.nix { inherit pkgs; };
          fleetApps = import ./lib/fleet.nix { inherit pkgs; };
          proxmox = import ./lib/proxmox-apps.nix {
            inherit inputs system;
          };
        in
        sopsApps // fleetApps // proxmox.apps
      );
      formatter = helpers.forAllSystems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "formatter";
          runtimeInputs = with pkgs; [
            coreutils
            nixfmt-tree
            shellcheck
            ruff
            nodejs
            eslint
            jq
            mbake
            actionlint
            markdownlint-cli2
            git
            findutils
          ];
          text = builtins.readFile ./scripts/formatter.sh;
        }
      );

    };
}
