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
      perSystem = helpers.forAllSystems (
        system:
        import ./per-system.nix {
          inherit
            inputs
            outputs
            system
            username
            ;
        }
      );
      selectPerSystem = outputName: builtins.mapAttrs (_: value: value.${outputName}) perSystem;

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

      apps = selectPerSystem "apps";
      checks = selectPerSystem "checks";
      formatter = selectPerSystem "formatter";
      nixosTests = import ./nixos-tests.nix { inherit inputs helpers; };

      overlays = import ./overlays { inherit inputs; };
      packages = selectPerSystem "packages";

    };
}
