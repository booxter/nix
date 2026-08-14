{ config, lib, ... }:
let
  layout = config.host.disko.layout;
  encrypted = builtins.isAttrs layout;
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
  luksLayoutType = lib.types.submodule {
    options.remoteUnlock = lib.mkOption {
      type = lib.types.nullOr remoteUnlockType;
      default = null;
      description = "Remote LUKS unlock through initrd SSH.";
    };
  };
in
{
  imports = [ ./remote-unlock.nix ];

  options.host.disko.layout = lib.mkOption {
    type = lib.types.nullOr (lib.types.either (lib.types.enum [ "plain" ]) luksLayoutType);
    default = null;
    description = "Plain or LUKS-encrypted managed root layout, or null when managed externally.";
  };

  config = lib.mkMerge [
    (lib.mkIf (layout == "plain") (import ./plain.nix { }))
    (lib.mkIf encrypted {
      host.autoUpgrade.claims.luks.reboot.cadence = "never";
    })
    (lib.mkIf encrypted (import ./luks.nix { }))
  ];
}
