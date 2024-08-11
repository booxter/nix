{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, home-manager, nix-darwin, nixpkgs }:
  let
    pkgs = import nixpkgs {
      system = "aarch64-darwin";
      config = { allowUnfree = true; };
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
          };
          home-manager.users.ihrachys = import modules/home-manager {
            inherit pkgs;
          };
        }
      ];
    };

    # Expose the package set, including overlays, for convenience.
    darwinPackages = self.darwinConfigurations."ihrachys-macpro".pkgs;
  };
}
