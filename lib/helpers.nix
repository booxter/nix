{
  inputs,
  outputs,
  ...
}:
let
  commonHMConfig =
    {
      inputs,
      outputs,
      username,
      isDesktop,
      isWork,
      stateVersion,
    }:
    {
      home-manager.extraSpecialArgs = {
        inherit
          inputs
          outputs
          username
          isDesktop
          isWork
          stateVersion
          ;
      };
      home-manager.useUserPackages = true;
      home-manager.users.${username} = ../home-manager;
    };
in
rec {
  mkHome =
    {
      stateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-darwin",
      isWork ? false,
      isDesktop ? false,
      extraModules ? [ ],
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
      ]
      ++ extraModules;
    };

  mkNixos =
    {
      hostname,
      stateVersion,
      username ? "ihrachyshka",
      platform ? "x86_64-linux",
      virtPlatform ? platform,
      withHome ? true,
      isDesktop ? false,
      isWork ? false,
      isVM ? false,
      sshPort ? null,
      extraModules ? [ ],
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
      ]
      ++ inputs.nixpkgs.lib.optionals withHome [
        inputs.home-manager.nixosModules.home-manager
        (commonHMConfig {
          inherit
            inputs
            outputs
            username
            isDesktop
            isWork
            stateVersion
            ;
        })

        (
          { ... }:
          let
            pkgs = inputs.nixpkgs.legacyPackages.${platform};
          in
          {
            users.defaultUserShell = pkgs.zsh;
          }
        )
      ]
      ++ extraModules;
    };

  mkProxmox =
    args@{ platform, extraModules, ... }:
    mkNixos (
      args
      // {
        withHome = false;
        extraModules = extraModules ++ [
          inputs.proxmox-nixos.nixosModules.proxmox-ve

          (
            { ... }:
            {
              services.proxmox-ve = {
                enable = true;
              };

              nixpkgs.overlays = [
                inputs.proxmox-nixos.overlays.${platform}
              ];
            }
          )
        ];
      }
    );

  mkRaspberryPi =
    {
      hostname,
      stateVersion,
      username ? "ihrachyshka",
      platform ? "aarch64-linux",
      isDesktop ? false,
      isWork ? false,
      isVM ? false,
      extraModules ? [ ],
    }:
    inputs.nixos-raspberrypi.lib.nixosSystem {
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
          isVM
          ;
        nixos-raspberrypi = inputs.nixos-raspberrypi;
      };
      system = platform;
      modules = [
        ../common
        ../nixos

        # configure binary cache substituters
        {
          nix = {
            settings = {
              extra-substituters = [
                "https://nixos-raspberrypi.cachix.org"
              ];
              extra-trusted-public-keys = [
                "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
              ];
            };
          };
        }

        # base hardware modules
        {
          imports = with inputs.nixos-raspberrypi.nixosModules; [
            sd-image
            raspberry-pi-5.base
            raspberry-pi-5.display-vc4
            raspberry-pi-5.bluetooth
          ];
        }

        # bootloader
        (
          { config, ... }:
          {
            system.nixos.tags =
              let
                cfg = config.boot.loader.raspberryPi;
              in
              [
                "raspberry-pi-${cfg.variant}"
                cfg.bootloader
                config.boot.kernelPackages.kernel.version
              ];
          }
        )

      ]
      ++ extraModules;
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
      extraModules ? [ ],
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

        inputs.home-manager.darwinModules.home-manager
        (commonHMConfig {
          inherit
            inputs
            outputs
            username
            isDesktop
            isWork
            ;
          stateVersion = hmStateVersion;
        })
      ]
      ++ extraModules;
    };

  forAllSystems = inputs.nixpkgs.lib.genAttrs [
    "aarch64-linux"
    "x86_64-linux"
    "aarch64-darwin"
    "x86_64-darwin"
  ];
}
