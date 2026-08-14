{ config, lib, ... }:
let
  clusterOption = lib.mkOption {
    type = lib.types.nonEmptyStr;
    description = "Proxmox cluster containing this host.";
  };
  nodeType = lib.types.submodule {
    options = {
      cluster = clusterOption;
      controller = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this node owns cluster-wide integrations.";
      };
      apiServerName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = config.networking.hostName;
        description = "Primary DNS name used for the Proxmox VE API.";
      };
    };
  };
  guestType = lib.types.submodule {
    options = {
      cluster = clusterOption;

      cores = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "Virtual CPU cores assigned to the Proxmox guest.";
      };

      memoryGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8;
        description = "Memory assigned to the Proxmox guest, in GiB.";
      };

      balloonGiB = lib.mkOption {
        type = with lib.types; nullOr ints.positive;
        default = null;
        description = "Minimum ballooned memory for the Proxmox guest, in GiB.";
      };

      diskGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 100;
        description = "Root disk size assigned to the Proxmox guest, in GiB.";
      };
    };
  };
in
{
  options.host.proxmox = {
    node = lib.mkOption {
      type = lib.types.nullOr nodeType;
      default = null;
      description = "Configuration for a Proxmox VE node.";
    };

    guest = lib.mkOption {
      type = lib.types.nullOr guestType;
      default = null;
      description = "Configuration for a declarative Proxmox guest.";
    };
  };
}
