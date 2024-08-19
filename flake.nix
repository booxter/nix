{
  description = "my work flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:LnL7/nix-darwin";
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

  outputs = { self, nixvim, home-manager, nix-darwin, nixpkgs, nur, emacs }:
  let
    pkgs = import nixpkgs {
      system = "aarch64-darwin";
      config = { allowUnfree = true; };
      overlays = [
        nur.overlay
        emacs.overlay
      ];
    };
    configuration = import ./modules/darwin {
      inherit self pkgs;
    };
  in
  {
    # Build darwin flake using:
    # $ darwin-rebuild build --flake .#
    darwinConfigurations."darwin" = nix-darwin.lib.darwinSystem {
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
    darwinPackages = self.darwinConfigurations."darwin".pkgs;
  };
}
