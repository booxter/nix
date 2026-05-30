{
  description = "booxter Nix* flake configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
    nixpkgs-25_11.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Keep Transmission pinned independently from the moving release-25.11 branch.
    # TODO: remove this input when trackers allow 4.1.0+.
    nixpkgs-transmission.url = "github:NixOS/nixpkgs/12d60a4f2d5f2cc96e93ae5615328245d49ac2e8";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    nix-darwin.url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs-darwin";

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

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    home-manager-25_11.url = "github:nix-community/home-manager/release-25.11";
    home-manager-25_11.inputs.nixpkgs.follows = "nixpkgs-25_11";

    nixvim.url = "github:nix-community/nixvim/nixos-26.05";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    proxmox-nixos.url = "github:booxter/proxmox-nixos/my-fork";

    disko.url = "github:nix-community/disko/latest";
    virby.url = "github:quinneden/virby-nix-darwin";
    debugserver.url = "github:reckenrode/nixpkgs/push-tnkmrvyqmzpu";

    # TODO: switch to official when diff is contributed upstream
    jellarr.url = "github:booxter/jellarr/my-fork-plus-fix-plugin-404";
    #jellarr.url = "github:venkyr77/jellarr/v0.1.0";
    jellarr.inputs.nixpkgs.follows = "nixpkgs";

    vpnconfinement.url = "github:Maroka-chan/VPN-Confinement";

    llm-agents.url = "github:numtide/llm-agents.nix";

    lolek = {
      url = "github:booxter/lolek/my-fork";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    tig = {
      url = "github:jonas/tig";
      flake = false;
    };

  };

  outputs =
    inputs@{ self, ... }:
    let
      inherit (self) outputs;
      username = "ihrachyshka";
      hostInventory = import ./lib/inventory.nix {
        inherit username;
        lib = inputs.nixpkgs.lib;
      };
      helpers = import ./lib {
        inherit
          hostInventory
          inputs
          outputs
          username
          ;
      };

      hostSpecs = hostInventory;
      inherit (hostSpecs)
        darwinHosts
        nixosHostSpecs
        toVmName
        virtPlatform
        ;

      hostKindToMkHost = {
        nixos = helpers.mkNixos;
        proxmox = helpers.mkProxmox;
        raspberryPi = helpers.mkRaspberryPi;
      };

      staticHostModule =
        spec:
        { lib, ... }:
        {
          config.host = lib.optionalAttrs (spec ? dnsName) {
            dnsName = spec.dnsName;
          };
        };

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

      BM = args: helpers.mkBM ({ inherit virtPlatform; } // args);

      specToNixosConfigs =
        spec:
        let
          extraModules = inputs.nixpkgs.lib.optionals (spec ? dnsName) [ (staticHostModule spec) ];
          args = builtins.removeAttrs spec [
            "type"
            "hostKind"
            "homeManagerInput"
            "nixpkgsInput"
            "dnsName"
          ];
          inputArgs =
            (if spec ? homeManagerInput then { homeManagerInput = inputs.${spec.homeManagerInput}; } else { })
            // (if spec ? nixpkgsInput then { nixpkgsInput = inputs.${spec.nixpkgsInput}; } else { });
        in
        if spec.type == "bm" then
          BM (
            args
            // inputArgs
            // {
              mkHost = hostKindToMkHost.${spec.hostKind};
              extraModules = (args.extraModules or [ ]) ++ extraModules;
            }
          )
        else if spec.type == "vm" then
          VM (args // { extraModules = (args.extraModules or [ ]) ++ extraModules; })
        else
          throw "Unsupported NixOS host spec type `${spec.type}`";

    in
    {
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

      nixosConfigurations = builtins.foldl' (
        acc: spec: acc // specToNixosConfigs spec
      ) { } nixosHostSpecs;

      checks = import ./checks.nix {
        inherit
          helpers
          inputs
          outputs
          ;
      };
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
          pkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [
              outputs.overlays.additions
              outputs.overlays.modifications
            ];
          };
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
            prettier
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
