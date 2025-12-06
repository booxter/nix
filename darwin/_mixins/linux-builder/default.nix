{ lib, ci, ... }:
{
  nix = {
    linux-builder = {
      enable = true;
    }
    // lib.optionalAttrs (!ci) {
      # if custom config is ever broken to the point the machine cannot start
      # and the builder itself cannot be rebuilt, just leave the enable = true
      # and temporarily disable the rest of settings to pull the builder image
      # from cache
      ephemeral = true;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      config =
        let
          emulatedSystems = [ "x86_64-linux" ];
        in
        {
          boot.binfmt.emulatedSystems = emulatedSystems;
          nix.settings.extra-platforms = emulatedSystems;
          virtualisation = {
            darwin-builder = {
              diskSize = 80 * 1024;
              memorySize = 12 * 1024;
            };
            cores = 8;
          };
        };
    };
    settings = {
      trusted-users = [ "@admin" ];
    };
  };

  # Collect logs for debugging purposes.
  launchd.daemons.linux-builder = {
    serviceConfig = {
      StandardOutPath = "/var/log/darwin-builder.log";
      StandardErrorPath = "/var/log/darwin-builder.log";
    };
  };
}
