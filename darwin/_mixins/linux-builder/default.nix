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

  # For unclear reasons, macos sometimes fails to resolve localhost for ssh... 127.0.0.1 seems to work.
  environment.etc."ssh/ssh_config.d/100-linux-builder.conf".text = lib.mkBefore ''
      Host linux-builder
        User builder
        Hostname 127.0.0.1
        HostKeyAlias linux-builder
        Port 31022
        IdentityFile /etc/nix/builder_ed25519
    '';
}
