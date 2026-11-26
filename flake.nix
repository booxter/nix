{
  description = "booxter Nix* flake configs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-26.11";
    # TODO(26.11): Drop when beast's required plugins support Jellyfin 12.
    nixpkgs-jellyfin.url = "https://releases.nixos.org/nixos/26.05/nixos-26.05.15079.0dc498bfe49b/nixexprs.tar.zst";
    nixpkgs-unstable.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";

    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    # TODO(26.11): Drop the fork module once upstream reconciles GUI agents.
    nix-darwin-launchd = {
      url = "github:booxter/nix-darwin/56814e3905de59744e112a2a8ecc7958a2d1edb5";
      flake = false;
    };

    nix-darwin-vm.url = "github:booxter/nix-darwin-vm";
    nix-darwin-vm.inputs.nixpkgs.follows = "nixpkgs";
    nix-darwin-vm.inputs.nix-darwin.follows = "nix-darwin";

    # Follow upstream's weekly database snapshots through flake updates.
    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    nix-homebrew.url = "github:zhaofengli/nix-homebrew";
    # Remove this override once nix-homebrew supports manifest_sha256.
    nix-homebrew.inputs.brew-src.url = "github:Homebrew/brew/7.0.15";
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

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    stylix.url = "github:nix-community/stylix/master";
    stylix.inputs.nixpkgs.follows = "nixpkgs";
    stylix.inputs.nur.follows = "nur";

    spicetify-nix.url = "github:Gerg-L/spicetify-nix";
    spicetify-nix.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim/main";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";
    nur.inputs.nixpkgs.follows = "nixpkgs";

    proxmox-nixos.url = "github:SaumonNet/proxmox-nixos/main";

    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # TODO: switch to official when diff is contributed upstream
    jellarr.url = "github:booxter/jellarr/my-fork-plus-fix-plugin-404";
    #jellarr.url = "github:venkyr77/jellarr/v0.1.0";
    jellarr.inputs.nixpkgs.follows = "nixpkgs";

    vpnconfinement.url = "github:Maroka-chan/VPN-Confinement";

    lolek = {
      url = "github:dziaineka/lolek";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    motion-captcha-bot = {
      url = "github:FrostBy/motion-captcha-bot";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.telegym.inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    inputs@{ self, ... }:
    let
      inherit (self) outputs;
      lib = inputs.nixpkgs.lib;
      hosts = import ./lib/hosts.nix { inherit lib; };
      fleetInventory = import ./inventory {
        fleetHosts = hosts;
        inherit lib;
      };
      sshKeys = fleetInventory.ssh;
      specialArgsForHost =
        {
          hostName,
          system,
        }:
        {
          backupConfigurations = outputs.nixosConfigurations;
          storageConfigurations = outputs.nixosConfigurations;
          inherit
            inputs
            outputs
            hostName
            fleetInventory
            sshKeys
            system
            ;
        };
      mkNixos =
        hostName: hostModule:
        let
          # Keep node modules and base packages on Proxmox's tested nixpkgs pin.
          nixpkgsInput =
            if builtins.hasAttr hostName fleetInventory.proxmox.nodes then
              inputs.proxmox-nixos.inputs.nixpkgs-stable
            else
              inputs.nixpkgs;
        in
        nixpkgsInput.lib.nixosSystem {
          specialArgs = specialArgsForHost {
            inherit hostName;
            system = "x86_64-linux";
          };
          modules = [
            ./nixos
            hostModule
          ];
        };
      mkDarwin =
        hostName: hostModule:
        inputs.nix-darwin.lib.darwinSystem {
          specialArgs = specialArgsForHost {
            inherit hostName;
            system = "aarch64-darwin";
          };
          modules = [
            ./darwin
            hostModule
          ];
        };
      perSystem =
        inputs.nixpkgs.lib.genAttrs
          [
            "x86_64-linux"
            "aarch64-darwin"
          ]
          (
            system:
            import ./per-system.nix {
              inherit
                inputs
                fleetInventory
                outputs
                system
                ;
            }
          );
      selectPerSystem = outputName: builtins.mapAttrs (_: value: value.${outputName}) perSystem;
    in
    {
      darwinConfigurations = builtins.mapAttrs mkDarwin hosts.darwin;
      nixosConfigurations = builtins.mapAttrs mkNixos hosts.nixos;

      apps = selectPerSystem "apps";
      checks = selectPerSystem "checks";
      formatter = selectPerSystem "formatter";
      packages = selectPerSystem "packages";
      updatePackages = selectPerSystem "update-packages";

      overlays = import ./overlays { inherit inputs fleetInventory; };

      lib.ci = {
        inherit (import ./ci { inherit hosts lib; }) buildTargets;
        checks = selectPerSystem "ci-checks";
      };
    };
}
