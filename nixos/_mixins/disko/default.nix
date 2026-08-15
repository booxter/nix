{ config, lib, ... }:
let
  layout = config.host.disko.layout;
  remoteUnlock = config.host.disko.remoteUnlock;
  unlockKey =
    key:
    ''no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc,command="systemctl default" ${key}'';
  remoteUnlockType = lib.types.submodule {
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
  };
in
{
  options.host.disko = {
    layout = lib.mkOption {
      type =
        with lib.types;
        nullOr (enum [
          "luks"
          "plain"
        ]);
      default = null;
      description = "Managed root layout, or null when managed externally.";
    };

    remoteUnlock = lib.mkOption {
      type = lib.types.nullOr remoteUnlockType;
      default = null;
      description = "Remote LUKS unlock through initrd SSH.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (layout == "plain") (import ./plain.nix { }))
    (lib.mkIf (layout == "luks") {
      host.autoUpgrade.claims.luks.reboot.cadence = "never";
    })
    (lib.mkIf (layout == "luks") (import ./luks.nix { }))
    (lib.mkIf (remoteUnlock != null) {
      boot.initrd = {
        availableKernelModules = remoteUnlock.kernelModules;
        network = {
          enable = true;
          ssh = {
            enable = true;
            hostKeys = [ remoteUnlock.hostKeyPath ];
            authorizedKeys = map unlockKey remoteUnlock.authorizedKeys;
          };
        };
        systemd.network = {
          enable = true;
          networks."10-${remoteUnlock.networkInterface}" = {
            matchConfig.Name = remoteUnlock.networkInterface;
            networkConfig.DHCP = "ipv4";
            linkConfig.RequiredForOnline = "routable";
          };
        };
      };
    })
    {
      assertions = [
        {
          assertion = config.host.disko.remoteUnlock == null || layout == "luks";
          message = "host.disko.remoteUnlock requires the LUKS layout";
        }
      ];
    }
  ];
}
