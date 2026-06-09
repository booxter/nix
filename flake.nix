{
  description = "booxter Nix* flake configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
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

    nixvim.url = "github:nix-community/nixvim/nixos-26.05";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";

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

    determinate-nix-installer = {
      url = "github:DeterminateSystems/nix-installer";
      flake = false;
    };

    lolek = {
      url = "github:booxter/lolek/local-bot-api-uploads";
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
        virtPlatform
        ;

      hostKindToMkHost = {
        nixos = helpers.mkNixos;
        proxmox = helpers.mkProxmox;
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
          ...
        }:
        let
          runtimeHostname = hostInventory.toNixosRuntimeHostName hostInventory.nixosHostSpecsByName.${name};
        in
        {
          "${name}" = helpers.mkVM (
            args
            // {
              inherit stateVersion;
              hostSpecName = name;
              hostname = runtimeHostname;
              platform = "x86_64-linux";
              virtPlatform = "x86_64-linux";
            }
          );
        };

      BM = args: helpers.mkBM args;

      specToNixosConfigs =
        spec:
        let
          extraModules = inputs.nixpkgs.lib.optionals (spec ? dnsName) [ (staticHostModule spec) ];
          args = builtins.removeAttrs spec [
            "hostKind"
            "isVM"
            "homeManagerInput"
            "nixpkgsInput"
            "dnsName"
          ];
          inputArgs =
            (if spec ? homeManagerInput then { homeManagerInput = inputs.${spec.homeManagerInput}; } else { })
            // (if spec ? nixpkgsInput then { nixpkgsInput = inputs.${spec.nixpkgsInput}; } else { });
        in
        if hostInventory.isNixosVM spec then
          VM (args // { extraModules = (args.extraModules or [ ]) ++ extraModules; })
        else
          BM (
            args
            // inputArgs
            // {
              mkHost = hostKindToMkHost.${spec.hostKind};
              extraModules = (args.extraModules or [ ]) ++ extraModules;
            }
          );

      canonicalNixosConfigurations = builtins.foldl' (
        acc: spec: acc // specToNixosConfigs spec
      ) { } nixosHostSpecs;

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
            value = helpers.mkDarwin (cfg // { hostSpecName = name; });
          }
        ) (builtins.attrNames darwinHosts)
      );

      nixosConfigurations = canonicalNixosConfigurations;

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
          basePackages = import ./pkgs pkgs;
          mkApp = program: description: {
            type = "app";
            inherit program;
            meta = { inherit description; };
          };
          darwinApps = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            lan-wan-bpf = mkApp "${basePackages.darwin-lan-wan-bpf}/bin/darwin-lan-wan-bpf" "Capture Darwin interface traffic and emit LAN/WAN byte counters using BPF.";
          };
          proxmox = import ./lib/proxmox-apps.nix {
            inherit inputs system;
          };
        in
        sopsApps // fleetApps // proxmox.apps // darwinApps
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
