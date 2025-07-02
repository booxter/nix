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
      hostname,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
    }:
    let
      isDesktop = hostname == "mmini";
    in
      inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = inputs.nixpkgs.legacyPackages.${platform};
        extraSpecialArgs = {
          inherit
            inputs
            outputs
            hostname
            platform
            username
            stateVersion
            isDesktop
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
    }:
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          username
          ;
      };
      modules = [
        inputs.nix-homebrew.darwinModules.nix-homebrew
        # An existing Linux builder is needed to initially bootstrap `nix-rosetta-builder`.
        # If one isn't already available: comment out the `nix-rosetta-builder` module below,
        # uncomment this `linux-builder` module, and run `darwin-rebuild switch`:
        # { nix.linux-builder.enable = true; }
        # Then: uncomment `nix-rosetta-builder`, remove `linux-builder`, and `darwin-rebuild switch`
        # a second time. Subsequently, `nix-rosetta-builder` can rebuild itself.
        inputs.nix-rosetta-builder.darwinModules.default
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
