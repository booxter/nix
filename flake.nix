{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nixpkgs_kitty_fix.url = "github:leiserfg/nixpkgs/fix-kitty-nerfont";

    # nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.url = "github:booxter/nix-darwin/suppress-gpg-connect-agent-stderr";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # home-manager.url = "github:nix-community/home-manager";
    # Use a fork with a fix for thunderbird and firefox profiles.ini Version=2
    # See: https://github.com/nix-community/home-manager/pull/5724
    # TODO: overlay just for the packages of interest
    home-manager.url = "github:booxter/home-manager/fix-thunderbird-aarch64";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";

    nur.url = "github:nix-community/NUR";
    nur.inputs.nixpkgs.follows = "nixpkgs";

    emacs.url = "github:nix-community/emacs-overlay";
    emacs.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, ... }:
  let
    mkPkgs = system:
      import inputs.nixpkgs {
        inherit system;
        config = { allowUnfree = true; };
        overlays = [
          inputs.nur.overlay
          inputs.emacs.overlay
          (final: prev: {
            inherit (inputs.nixpkgs_kitty_fix.legacyPackages.${prev.system})
              kitty;
          })
        ];
      };
    mkHome = username: modules: {
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "backup";
        extraSpecialArgs = {inherit inputs username; };
        users."${username}".imports = modules;
      };
    };
    globalModules = { username }: [
      {
        system.configurationRevision = self.rev or self.dirtyRev or null;
      }
      (mkHome username [
        ./modules/home-manager
        inputs.nixvim.homeManagerModules.nixvim
      ])
    ];
    globalModulesMacos = { username }: globalModules { inherit username; } ++ [
      ./modules/darwin
      inputs.home-manager.darwinModules.home-manager
      # ./modules/home-manager/darwin.nix
    ];
  in
  {
    darwinConfigurations = let
      username = "ihrachys";
    in {
      macpro = inputs.nix-darwin.lib.darwinSystem rec {
        system = "aarch64-darwin";
        pkgs = mkPkgs system;
        specialArgs = {
          inherit username;
        };
        modules = (globalModulesMacos { inherit username; }) ++ [
          ./hosts/macpro/configuration.nix
        ];
      };
    };
  };
}
