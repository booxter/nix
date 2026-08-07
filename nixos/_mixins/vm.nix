{
  config,
  hostSpec,
  inputs,
  lib,
  modulesPath,
  ...
}:
let
  username = config.host.username;
  isVM = hostSpec.isVM or false;
  cores = hostSpec.cores or 4;
  memorySize = hostSpec.memorySize or 8;
  diskSize = hostSpec.diskSize or 100;
  sshPort = hostSpec.sshPort or null;
  virtPlatform = hostSpec.virtPlatform or hostSpec.platform;
in
{
  imports = lib.optionals isVM [ (modulesPath + "/profiles/qemu-guest.nix") ];

  config = lib.mkIf config.host.isVM {
    services.getty.autologinUser = username;
    services.qemuGuest.enable = true;

    virtualisation.vmVariant.virtualisation = {
      host.pkgs = inputs.nixpkgs.legacyPackages.${virtPlatform};
      graphics = false;
      # Limit cores to avoid overloading the local host.
      cores = inputs.nixpkgs.lib.min cores 8;
      memorySize = memorySize * 1024;
      diskSize = diskSize * 1024;
      forwardPorts = lib.optionals (sshPort != null) [
        {
          from = "host";
          guest.port = 22;
          host.port = sshPort;
        }
      ];
    };

    system.build.vmQemu = config.virtualisation.vmVariant.virtualisation.host.pkgs.qemu;
  };
}
