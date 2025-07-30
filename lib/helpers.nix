{
  inputs,
  outputs,
  stateVersion,
  ...
}:
{
  # Helper function for generating home-manager configs
  mkHome =
    {
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      isPrivate,
      isDesktop,
    }:
    inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = inputs.nixpkgs.legacyPackages.${platform};
      extraSpecialArgs = {
        inherit
          inputs
          outputs
          username
          stateVersion
          isDesktop
          isPrivate
          ;
      };
      modules = [ ../home-manager ];
    };

  # Helper function for generating NixOS configs
  mkNixos =
    {
      hostname,
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
      modules = [ ../nixos ];
    };

  mkDarwin =
    {
      hostname,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      isDesktop ? true,
      isPrivate,
    }:
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          username
          isDesktop
          isPrivate
          ;
      };
      modules = [
        inputs.nix-homebrew.darwinModules.nix-homebrew
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
