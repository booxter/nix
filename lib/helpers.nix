{
  defaultUsername,
  hostInventory,
  inputs,
  outputs,
  ...
}:
let
  commonHMConfig =
    { username, ... }@hostArgs:
    {
      home-manager.extraSpecialArgs = {
        inherit inputs hostInventory;
      }
      // hostArgs;
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.${username} = ../home-manager;
    };
  upsNonVmShutdownDelaySeconds = 900;
  upsShutdownDelaySeconds =
    isVM: if isVM then builtins.div upsNonVmShutdownDelaySeconds 2 else upsNonVmShutdownDelaySeconds;
in
rec {
  mkNixos =
    {
      hostname,
      stateVersion,
      hostSpecName ? hostname,
      username ? defaultUsername,
      platform,
      virtPlatform ? platform,
      homeManagerInput ? inputs.home-manager,
      hmFull ? true,
      isBuilder ? false,
      isDesktop ? false,
      isLaptop ? false,
      isWork ? false,
      secretDomain ? (if isWork then "work" else "main"),
      isVM ? false,
      nixpkgsInput ? inputs.nixpkgs,
      extraModules ? [ ],
      ...
    }:
    let
      hostPlatform = nixpkgsInput.lib.systems.elaborate platform;
    in
    nixpkgsInput.lib.nixosSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostInventory
          hostname
          hostSpecName
          hostPlatform
          virtPlatform
          username
          stateVersion
          isVM
          isBuilder
          isDesktop
          isLaptop
          isWork
          secretDomain
          ;
        upsShutdownDelaySeconds = upsShutdownDelaySeconds isVM;
      };
      modules = [
        inputs.stylix.nixosModules.stylix
        ../common
        ../nixos
        inputs.disko.nixosModules.disko
        inputs.sops-nix.nixosModules.sops
        homeManagerInput.nixosModules.home-manager
        (commonHMConfig {
          inherit
            username
            hostSpecName
            hmFull
            isDesktop
            isWork
            stateVersion
            ;
        })
      ]
      ++ extraModules;
    };

  mkVM =
    args@{
      extraModules ? [ ],
      sshPort ? null,
      username ? defaultUsername,
      platform,
      virtPlatform ? platform,
      cores ? 4,
      memorySize ? 8, # GB
      diskSize ? 100, # GB
      ...
    }:
    mkNixos (
      args
      // {
        isVM = true;
        extraModules =
          extraModules
          ++ [
            {
              services.getty.autologinUser = username;
            }

            (
              { modulesPath, ... }:
              {
                imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
                services.qemuGuest.enable = true;
              }
            )

            # build-vm (local) vms
            {
              virtualisation.vmVariant.virtualisation = {
                host.pkgs = inputs.nixpkgs.legacyPackages.${virtPlatform};
                graphics = false;
                # limit cores to avoid overloading host
                cores = inputs.nixpkgs.lib.min cores 8;
                memorySize = memorySize * 1024;
                diskSize = diskSize * 1024;
              };
            }
            (
              { config, ... }:
              {
                system.build.vmQemu = config.virtualisation.vmVariant.virtualisation.host.pkgs.qemu;
              }
            )
          ]
          ++ inputs.nixpkgs.lib.optionals (sshPort != null) [
            {
              virtualisation.vmVariant.virtualisation.forwardPorts = [
                {
                  from = "host";
                  guest.port = 22;
                  host.port = sshPort;
                }
              ];
            }
          ];
      }
    );

  mkDarwin =
    {
      hostname,
      stateVersion,
      hmStateVersion,
      username ? defaultUsername,
      platform,
      hostSpecName ? hostname,
      homeManagerInput ? inputs.home-manager,
      hmFull ? true,
      isBuilder ? false,
      isDesktop ? false,
      isLaptop ? false,
      isWork ? false,
      secretDomain ? (if isWork then "work" else "main"),
      extraModules ? [ ],
      ...
    }:
    let
      hostPlatform = inputs.nixpkgs.lib.systems.elaborate platform;
      isVM = false;
    in
    inputs.nix-darwin.lib.darwinSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostInventory
          hostname
          hostSpecName
          hostPlatform
          username
          stateVersion
          hmStateVersion
          hmFull
          isBuilder
          isDesktop
          isLaptop
          isWork
          secretDomain
          isVM
          ;
        # If we ever add macOS VMs, thread isVM here and compute accordingly.
        upsShutdownDelaySeconds = upsShutdownDelaySeconds false;
      };
      modules = [
        inputs.nix-homebrew.darwinModules.nix-homebrew
        inputs.sops-nix.darwinModules.sops
        inputs.stylix.darwinModules.stylix
        ../common
        ../darwin

        homeManagerInput.darwinModules.home-manager
        (commonHMConfig {
          inherit
            username
            hostSpecName
            hmFull
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
  ];
}
