{
  inputs,
  outputs,
  ...
}:
{
  # Helper function for generating home-manager configs
  mkHome =
    {
      stateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      isWork ? false,
      isDesktop ? false,
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs.legacyPackages.${platform};
      extraSpecialArgs = {
        inherit
          inputs
          outputs
          username
          platform
          stateVersion
          isDesktop
          isWork
          ;
      };
      modules = [
        inputs.nixvim.homeManagerModules.nixvim
        ../home-manager
      ];
    };

  # Helper function for generating NixOS configs
  mkNixos =
    {
      hostname,
      stateVersion,
      username ? "ihrachyshka",
      platform ? "x86_64-linux",
    }:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          username
          stateVersion
          ;
      };
      modules = [
        ../common
        ../nixos
      ];
    };

  mkDarwin =
    {
      hostname,
      stateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      isDesktop ? false,
      isWork ? false,
    }:
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          username
          stateVersion
          isDesktop
          isWork
          ;
      };
      modules = [
        inputs.nix-homebrew.darwinModules.nix-homebrew
        ../common
        ../darwin
      ];
    };

  forAllSystems = inputs.nixpkgs.lib.genAttrs [
    "aarch64-linux"
    "x86_64-linux"
    "aarch64-darwin"
    "x86_64-darwin"
  ];
}
