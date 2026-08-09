{
  config,
  lib,
  ...
}:
let
  cfg = config.host.luks.remoteUnlock;
in
{
  options.host.luks.remoteUnlock = {
    enable = lib.mkEnableOption "remote LUKS unlock through initrd SSH";

    kernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Kernel modules made available in the initrd for remote unlock.";
    };

    networkInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Network interface configured through DHCP in the initrd.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys authorized to unlock LUKS in the initrd.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.host.luks.enable;
        message = "host.luks.remoteUnlock requires host.luks.enable";
      }
      {
        assertion = cfg.networkInterface != null;
        message = "host.luks.remoteUnlock requires a networkInterface";
      }
      {
        assertion = cfg.authorizedKeys != [ ];
        message = "host.luks.remoteUnlock requires at least one authorized key";
      }
    ];

    boot.initrd = {
      availableKernelModules = cfg.kernelModules;
      network = {
        enable = true;
        ssh = {
          enable = true;
          hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
          inherit (cfg) authorizedKeys;
        };
      };
      systemd.network = {
        enable = true;
        networks = lib.optionalAttrs (cfg.networkInterface != null) {
          "10-${cfg.networkInterface}" = {
            matchConfig.Name = cfg.networkInterface;
            networkConfig.DHCP = "ipv4";
            linkConfig.RequiredForOnline = "routable";
          };
        };
      };
    };
  };
}
