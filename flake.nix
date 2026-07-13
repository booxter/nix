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

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim/nixos-26.05";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";

    proxmox-nixos.url = "github:booxter/proxmox-nixos/my-fork";

    disko.url = "github:nix-community/disko/latest";
    debugserver.url = "github:reckenrode/nixpkgs/push-tnkmrvyqmzpu";

    # TODO: switch to official when diff is contributed upstream
    jellarr.url = "github:booxter/jellarr/my-fork-plus-fix-plugin-404";
    #jellarr.url = "github:venkyr77/jellarr/v0.1.0";
    jellarr.inputs.nixpkgs.follows = "nixpkgs";

    vpnconfinement.url = "github:Maroka-chan/VPN-Confinement";

    llm-agents.url = "github:numtide/llm-agents.nix";

    codex-desktop-linux = {
      url = "github:ilysenko/codex-desktop-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate-nix-installer = {
      url = "github:DeterminateSystems/nix-installer";
      flake = false;
    };

    lolek = {
      url = "github:dziaineka/lolek";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # TODO: Drop once XQuartz fixes from NixOS/nixpkgs#537679 reach
    # nixpkgs-26.05-darwin.
    nixpkgs-xquartz-pr.url = "github:NixOS/nixpkgs/4a35131769a3c06c37232d60a1c3f1eb37392377";

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
      darwinConfigurations = builtins.mapAttrs (
        name: cfg: helpers.mkDarwin (cfg // { hostSpecName = name; })
      ) darwinHosts;

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
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          basePackages = import ./pkgs pkgs;
          nvPackages = import ./home-manager/_mixins/nv/pkgs { inherit pkgs; };
          fleetPackages = {
            inherit (inputs.disko.packages.${system}) disko-install;
          };
          updateTargetPackages =
            pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
              aurral = pkgs.callPackage ./nixos/srvarr/pkgs/aurral { };
              houndarr = pkgs.callPackage ./nixos/srvarr/pkgs/houndarr { };
              searchless-ngx = pkgs.callPackage ./nixos/org/pkgs/searchless-ngx { };
              telegram-archive = pkgs.callPackage ./nixos/org/pkgs/telegram-archive { };
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
          sopsApps = import ./apps/sops { inherit pkgs; };
          packageUpdateApps = import ./apps/package-updates { inherit pkgs; };
          fleetApps = import ./apps/fleet.nix {
            inherit pkgs username;
          };
          darwinPackages = import ./darwin/pkgs pkgs;
          mkApp = program: description: {
            type = "app";
            inherit program;
            meta = { inherit description; };
          };
          get-ff-cookie = pkgs.writeShellApplication {
            name = "get-ff-cookie";
            runtimeInputs = with pkgs; [
              coreutils
              gallery-dl
              gnugrep
            ];
            text = builtins.readFile ./apps/get-ff-cookie.sh;
          };
          cookieApps = {
            get-ff-cookie = mkApp "${get-ff-cookie}/bin/get-ff-cookie" "Export Firefox cookies as Netscape cookies.txt on stdout.";
          };
          darwinApps = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
            lan-wan-bpf = mkApp "${darwinPackages.darwin-lan-wan-bpf}/bin/darwin-lan-wan-bpf" "Capture Darwin interface traffic and emit LAN/WAN byte counters using BPF.";
          };
          proxmox = import ./apps/proxmox.nix {
            inherit inputs system;
          };
        in
        sopsApps // packageUpdateApps // fleetApps // proxmox.apps // cookieApps // darwinApps
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
            # TODO: reenable when https://github.com/NixOS/nixpkgs/pull/540892 reaches nixos-26.05
            #prettier
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
