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

  options.host.luks.remoteUnlock = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          kernelModules = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Kernel modules made available in the initrd for remote unlock.";
          };

          networkInterface = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = config.host.network.primaryInterface;
            description = "Network interface configured through DHCP in the initrd.";
          };

          authorizedKeys = lib.mkOption {
            type = with lib.types; nonEmptyListOf nonEmptyStr;
            description = "SSH public keys authorized to unlock LUKS in the initrd.";
          };

          hostKeyPath = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Path to the manually provisioned initrd SSH private host key.";
          };
        };
      }
    );
    default = null;
    description = "Remote LUKS unlock through initrd SSH.";
  };

  config = lib.mkIf (cfg != null) {
    boot.initrd = {
      availableKernelModules = cfg.kernelModules;
      network = {
        enable = true;
        ssh = {
          enable = true;
          hostKeys = [ cfg.hostKeyPath ];
          authorizedKeys = map unlockKey cfg.authorizedKeys;
        };
      };
      systemd.network = {
        enable = true;
        networks = {
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
