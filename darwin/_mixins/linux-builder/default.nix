{ lib, ... }: {
  nix = {
    linux-builder = {
      # if custom config is ever broken to the point the machine cannot start
      # and the builder itself cannot be rebuilt, just leave the enable = true
      # and temporarily disable the rest of settings to pull the builder image
      # from cache
      enable = true;
      ephemeral = true;
      systems = ["aarch64-linux"];
      config = {
        virtualisation = {
          darwin-builder = {
            diskSize = 80 * 1024;
            memorySize = 20 * 1024;
          };
          cores = 4;
        };
      };
    };
    settings = {
      trusted-users = [ "@admin" ];
    };
  };

  # Collect logs for debugging purposes.
  launchd.daemons.linux-builder = { serviceConfig = { StandardOutPath = "/var/log/darwin-builder.log"; StandardErrorPath = "/var/log/darwin-builder.log"; }; };
}
