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
        beast = {
          address = "192.168.16.3";
          macAddress = "bc:fc:e7:3b:fe:da";
        };
        cache = {
          address = "192.168.20.7";
          macAddress = "bc:24:11:0d:85:41";
        };
        fana = {
          address = "192.168.13.110";
          macAddress = "bc:24:11:06:e8:8b";
        };
        frame = {
          address = "192.168.11.228";
          macAddress = "9c:bf:0d:00:fa:0a";
        };
        gw = {
          address = "192.168.20.3";
          macAddress = "bc:24:11:91:b5:77";
        };
        home = {
          address = "192.168.20.6";
          macAddress = "02:48:4f:4d:45:01";
        };
        mdx = {
          address = "192.168.10.100";
          macAddress = "7c:b7:7b:04:05:99";
        };
        nvws = {
          address = "192.168.15.100";
          macAddress = "ac:b4:80:40:05:2e";
        };
        org = {
          address = "192.168.20.4";
          macAddress = "bc:24:11:fd:eb:9c";
        };
        pki = {
          address = "192.168.20.5";
          macAddress = "bc:24:11:c6:ab:fc";
        };
        prx1-lab = {
          address = "192.168.15.10";
          macAddress = "38:05:25:30:7d:89";
        };
        prx2-lab = {
          address = "192.168.15.11";
          macAddress = "38:05:25:30:7f:7d";
        };
        prx3-lab = {
          address = "192.168.15.12";
          macAddress = "38:05:25:30:7d:69";
        };
        srvarr = {
          address = "192.168.20.2";
          macAddress = "bc:24:11:19:4d:d1";
        };
        sw-lab = {
          address = "192.168.15.1";
          macAddress = "78:2d:7e:24:2d:f9";
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
