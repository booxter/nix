{
  config,
  lib,
  ...
}:
let
  cfg = config.host.luks.remoteUnlock;
  unlockKey =
    key:
    ''no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc,command="systemctl default" ${key}'';
in
{
  imports = [ ./remote-unlock/assertions.nix ];

  options.host.luks.remoteUnlock = {
    kernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Kernel modules made available in the initrd for remote unlock.";
    };

    networkInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = config.host.network.primaryInterface;
      description = "Network interface configured through DHCP in the initrd.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys authorized to unlock LUKS in the initrd.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.initrd = {
      availableKernelModules = cfg.kernelModules;
      network = {
        enable = true;
        ssh = {
          enable = true;
          hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
          authorizedKeys = map unlockKey cfg.authorizedKeys;
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
