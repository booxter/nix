{
  description = "booxter Nix* flake configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-darwin.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
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
    cocoa-way-homebrew-tap = {
      url = "github:J-x-Z/homebrew-tap";
      flake = false;
    };

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    stylix.url = "github:nix-community/stylix/release-26.05";
    stylix.inputs.nixpkgs.follows = "nixpkgs";

    spicetify-nix.url = "github:Gerg-L/spicetify-nix";
    spicetify-nix.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim/nixos-26.05";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";
    nur.inputs.nixpkgs.follows = "nixpkgs";

    proxmox-nixos.url = "github:booxter/proxmox-nixos/my-fork";

    disko.url = "github:nix-community/disko/latest";

    # TODO: switch to official when diff is contributed upstream
    jellarr.url = "github:booxter/jellarr/my-fork-plus-fix-plugin-404";
    #jellarr.url = "github:venkyr77/jellarr/v0.1.0";
    jellarr.inputs.nixpkgs.follows = "nixpkgs";

    vpnconfinement.url = "github:Maroka-chan/VPN-Confinement";

    determinate-nix-installer = {
      url = "github:DeterminateSystems/nix-installer";
      flake = false;
    };

    lolek = {
      url = "github:dziaineka/lolek";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    inputs@{ self, ... }:
    let
      inherit (self) outputs;
      username = "ihrachyshka";
      hostInventory = import ./lib/inventory {
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

      specToNixosConfig =
        name: spec:
        let
          extraModules = inputs.nixpkgs.lib.optional (spec ? dnsName) {
            host.dnsName = spec.dnsName;
          };
          args = removeAttrs spec [
            "hostKind"
            "isVM"
            "dnsName"
            "name"
          ];
          hostArgs = args // {
            extraModules = (args.extraModules or [ ]) ++ extraModules;
            hostname = name;
            hostSpecName = name;
          };
        in
        if hostInventory.isNixosVM spec then
          helpers.mkVM (hostArgs // { stateVersion = args.stateVersion or "25.11"; })
        else
          helpers.mkNixos hostArgs;

    in
    {
      darwinConfigurations = builtins.mapAttrs (
        name: cfg:
        helpers.mkDarwin (
          cfg
          // {
            hostname = name;
            hostSpecName = name;
          }
        )
      ) hostInventory.darwinHosts;

      nixosConfigurations = builtins.mapAttrs specToNixosConfig hostInventory.nixosHostSpecsByName;

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
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          basePackages = import ./pkgs pkgs;
          nvPackages = import ./home-manager/_mixins/nv/pkgs { inherit pkgs; };
          orgPackages = import ./nixos/org/pkgs pkgs;
          fleet = import ./apps/fleet.nix {
            inherit pkgs username;
          };
          fleetPackages = {
            inherit (inputs.disko.packages.${system}) disko-install;
            fleet-tools = fleet.packages.fleet-tools;
          };
          updateTargetPackages =
            pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
              aurral = pkgs.callPackage ./nixos/srvarr/pkgs/aurral { };
              inherit (orgPackages)
                degoog
                degoog-devinside-extensions
                degoog-georgvwt-extensions
                degoog-official-extensions
                degoog-stackexchange-engine
                degoog-toolkit-extensions
                ;
              ebook-converter-cli = pkgs.callPackage ./nixos/srvarr/pkgs/ebook-converter-cli { };
              houndarr = pkgs.callPackage ./nixos/srvarr/pkgs/houndarr { };
            }
            // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
              ismc = pkgs.callPackage ./darwin/pkgs/ismc { };
            }
            # nix-update runs on GitHub-hosted Linux. Expose this Darwin-only
            # package there so its fixed-output source can be prefetched without
            # trying to build an aarch64-darwin fetcher on Linux.
            // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
              ismc = pkgs.callPackage ./darwin/pkgs/ismc { };
            }
            // {
              inherit (nvPackages) nico-cli;
            };
        in
        basePackages
        // fleetPackages
        // updateTargetPackages
        // {
          qemu-host-package = inputs.nixpkgs.legacyPackages.${system}.qemu;
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
        in
        import ./apps {
          inherit
            inputs
            pkgs
            system
            username
            ;
        }
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
            deadnix
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
          text = builtins.readFile ./apps/formatter.sh;
        }
      );

    };
}
