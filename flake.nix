{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    # home-manager.url = "github:nix-community/home-manager";
    # Use a fork with a fix for profiles.ini Version=2 breaking change
    # See: https://github.com/nix-community/home-manager/pull/5724
    home-manager.url = "github:HyunggyuJang/home-manager/fix/firefox-darwin";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nixvim.url = "github:nix-community/nixvim";
    nixvim.inputs.nixpkgs.follows = "nixpkgs";
    nur.url = "github:nix-community/NUR";
    nur.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixvim, home-manager, nix-darwin, nixpkgs, nur }:
  let
    pkgs = import nixpkgs {
      system = "aarch64-darwin";
      config = { allowUnfree = true; };
      overlays = [
        nur.overlay
      ];
    };
    configuration = import ./modules/darwin {
      inherit self pkgs;
    };
  in
  {
    # Build darwin flake using:
    # $ darwin-rebuild build --flake .#
    darwinConfigurations."ihrachys-macpro" = nix-darwin.lib.darwinSystem {
      modules = [
        configuration
        home-manager.darwinModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "backup";
            extraSpecialArgs = { inherit pkgs; };
          };
          home-manager.users.ihrachys.imports = [
            nixvim.homeManagerModules.nixvim
            ./modules/home-manager
          ];
        }
      ];
    };

    # Expose the package set, including overlays, for convenience.
    darwinPackages = self.darwinConfigurations."ihrachys-macpro".pkgs;
  };
}
