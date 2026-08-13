{ lib, ... }:
{
  options.host.proxmox = {
    cluster = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Proxmox cluster claimed by this node or guest.";
    };

    node.enable = lib.mkEnableOption "Proxmox VE node";

    guest = {
      enable = lib.mkEnableOption "declarative Proxmox guest";

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
}
