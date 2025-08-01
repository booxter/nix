{
  inputs,
  outputs,
  ...
}:
{
  mkHome =
    {
      stateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      isWork ? false,
      isDesktop ? false,
      extraModules ? [],
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
        ../home-manager
      ] ++ extraModules;
    };

  mkNixos =
    {
      hostname,
      stateVersion,
      username ? "ihrachyshka",
      platform ? "x86_64-linux",
      virtPlatform ? platform,
      isDesktop ? false,
      isWork ? false,
      isVM ? false,
      sshPort ? null,
      extraModules ? [],
    }:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostname
          platform
          virtPlatform
          username
          stateVersion
          isVM
          sshPort
          isDesktop
          isWork
          ;
        };
      modules = [
        ../common
        ../nixos

        inputs.home-manager.nixosModules.home-manager {
          home-manager.extraSpecialArgs = {
            inherit
              inputs
              outputs
              stateVersion
              username
              isDesktop
              isWork
              ;
          };
          home-manager.useUserPackages = true;
          home-manager.users.${username} = ../home-manager;
        }
      ] ++ extraModules;
    };

  mkDarwin =
    {
      hostname,
      stateVersion,
      hmStateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      isDesktop ? false,
      isWork ? false,
      extraModules ? [],
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
          hmStateVersion
          isDesktop
          isWork
          ;
      };
      modules = [
        inputs.nix-homebrew.darwinModules.nix-homebrew
        ../common
        ../darwin

        inputs.home-manager.darwinModules.home-manager {
          home-manager.extraSpecialArgs = {
            inherit
              inputs
              outputs
              username
              isDesktop
              isWork
              ;
            stateVersion = hmStateVersion;
          };
          home-manager.useUserPackages = true;
          home-manager.users.${username} = ../home-manager;
        }
      ] ++ extraModules;
    };

  forAllSystems = inputs.nixpkgs.lib.genAttrs [
    "aarch64-linux"
    "x86_64-linux"
    "aarch64-darwin"
    "x86_64-darwin"
  ];
}
