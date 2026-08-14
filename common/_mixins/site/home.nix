{ config, lib, ... }:
lib.mkIf (config.host.site.name == "home") {
  host.site = {
    timeZone = lib.mkDefault "America/New_York";

    uplink = {
      downloadMbit = lib.mkDefault 1000;
      uploadMbit = lib.mkDefault 40;
    };

    policies = {
      backups.maxUploadMbit = lib.mkDefault 10;
      downloaders.maxDownloadMbit = lib.mkDefault 400;
    };

    lan = {
      cidr = lib.mkDefault "192.168.0.0/16";
      reservations = lib.mkDefault {
        mdx = {
          identifiers = [ "7c:b7:7b:04:05:99" ];
          address = "192.168.10.100";
        };
        sw-lab = {
          identifiers = [ "78:2d:7e:24:2d:f9" ];
          address = "192.168.15.1";
        };
      };
      gateway = {
        host = lib.mkDefault "gateway";
        address = lib.mkDefault "192.168.0.1";
      };
      ipController = lib.mkDefault {
        flavor = "unifi";
        endpoint = "https://unifi";
        site = "default";
      };
      dhcp.ranges.main = lib.mkDefault [
        {
          # Keep the pool below 192.168.15.0/24 because that block is
          # reserved for the lab/proxmox segment.
          start = "192.168.10.1";
          end = "192.168.14.255";
        }
      ];
      netboot = {
        host = lib.mkDefault "prx1-lab";
        bootFile = lib.mkDefault "netboot.xyz.efi";
      };
      customDhcpOptions = lib.mkDefault {
        domainSearch = {
          code = 119;
          name = "DomainSearch";
          type = "text";
          signed = false;
          encoding = "text";
        };
        classlessStaticRoutes = {
          code = 121;
          name = "ClasslessStaticRoutes";
          type = "text";
          signed = false;
          encoding = "text";
        };
      };
    };
  };
}
