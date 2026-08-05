{
  defaultUsername,
  hostInventory,
  inputs,
  outputs,
}:
let
  upsNonVmShutdownDelaySeconds = 900;
  upsShutdownDelaySeconds =
    isVM: if isVM then builtins.div upsNonVmShutdownDelaySeconds 2 else upsNonVmShutdownDelaySeconds;

  mkNixos =
    {
      name,
      stateVersion,
      username ? defaultUsername,
      platform,
      virtPlatform ? platform,
      hmFull ? true,
      isBuilder ? false,
      isDesktop ? false,
      isLaptop ? false,
      isWork ? false,
      secretDomain ? (if isWork then "work" else "main"),
      isVM ? false,
      extraModules ? [ ],
      ...
    }:
    let
      hostname = name;
      hostPlatform = inputs.nixpkgs.lib.systems.elaborate platform;
    in
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit
          inputs
          outputs
          hostInventory
          hostname
          hostPlatform
          virtPlatform
          username
          stateVersion
          hmFull
          isVM
          isBuilder
          isDesktop
          isLaptop
          isWork
          secretDomain
          ;
        upsShutdownDelaySeconds = upsShutdownDelaySeconds isVM;
      };
      modules = [ ./default.nix ] ++ extraModules;
    };
in
{
  inherit mkNixos;

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
}
