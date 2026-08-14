{ lib, ... }:
let
  ip = import ../../_lib/ipv4.nix { inherit lib; };
  positiveNumber = lib.types.addCheck lib.types.number (value: value > 0);
  ipv4Address = lib.types.addCheck lib.types.nonEmptyStr ip.validIpv4;
  ipv4Cidr = lib.types.addCheck lib.types.nonEmptyStr ip.validCidr;
  reservationType = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = ipv4Address;
        description = "Reserved IPv4 address.";
      };
      macAddress = lib.mkOption {
        type = lib.types.strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}";
        description = "MAC address matching this reservation.";
      };
    };
  };
  dhcpRangeType = lib.types.submodule {
    options = {
      start = lib.mkOption {
        type = ipv4Address;
        description = "First IPv4 address in the DHCP pool.";
      };
      end = lib.mkOption {
        type = ipv4Address;
        description = "Last IPv4 address in the DHCP pool.";
      };
    };
  };
  ipControllerType = lib.types.submodule {
    options = {
      endpoint = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "API endpoint of the site IP controller.";
      };
      site = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Controller-local site identifier.";
      };
    };
  };
in
{
  options.host.site = {
    name = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "home";
      description = "Physical site containing this host.";
    };

    timeZone = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "IANA timezone of the physical site.";
    };

    uplink = {
      downloadMbit = lib.mkOption {
        type = positiveNumber;
        description = "Physical site download capacity in Mbit/s.";
      };

      uploadMbit = lib.mkOption {
        type = positiveNumber;
        description = "Physical site upload capacity in Mbit/s.";
      };
    };

    policies = {
      backups.maxUploadMbit = lib.mkOption {
        type = positiveNumber;
        description = "Maximum site upload rate allocated to backups in Mbit/s.";
      };

      downloaders.maxDownloadMbit = lib.mkOption {
        type = positiveNumber;
        description = "Maximum site download rate allocated to downloaders in Mbit/s.";
      };
    };

    lan = {
      cidr = lib.mkOption {
        type = ipv4Cidr;
        description = "IPv4 subnet of the physical site LAN.";
      };

      gateway = {
        address = lib.mkOption {
          type = ipv4Address;
          description = "IPv4 address of the site gateway.";
        };
      };

      ipController = lib.mkOption {
        type = ipControllerType;
        description = "UniFi IP controller serving the physical site.";
      };

      reservations = lib.mkOption {
        type = lib.types.attrsOf reservationType;
        default = { };
        description = "Authoritative IPv4 reservation inventory for the site.";
      };

      dhcp.range = lib.mkOption {
        type = dhcpRangeType;
        description = "DHCP range managed for the site.";
      };

      netboot = {
        host = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "Fleet host serving network boot files.";
        };
        bootFile = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "UEFI network boot filename.";
        };
      };

    };
  };
}
