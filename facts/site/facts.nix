{
  context,
  facts,
}:
let
  inherit (context) lanDomain publicDomain;
  nixCaches = facts.nix-caches;
  publicKeys = facts.public-keys;
in
rec {
  public = {
    domain = publicDomain;
  };

  ports = {
    watchstate = 8080;
  };

  inherit nixCaches;

  lan = {
    domain = lanDomain;
    cidr = "192.168.0.0/16";
    reservations = [
      {
        identifiers = [ "7c:b7:7b:04:05:99" ];
        hostname = "mdx";
        ip = "192.168.10.100";
      }
      {
        identifiers = [ "78:2d:7e:24:2d:f9" ];
        hostname = "sw-lab";
        ip = "192.168.15.1";
      }
    ];
    gateway = {
      host = "gateway";
      address = "192.168.0.1";
    };
    dhcpRanges = {
      main = {
        ranges = [
          {
            # Keep the pool below 192.168.15.0/24 because that block is
            # reserved for the lab/proxmox segment.
            start = "192.168.10.1";
            end = "192.168.14.255";
          }
        ];
      };
    };
    netboot = {
      host = "prx1-lab";
      bootfile = "netboot.xyz.efi";
    };
    customDhcpOptions = {
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

  wireguard.home = {
    cidr = "10.83.0.0/24";
    gateway = {
      host = "gw";
      address = "10.83.0.1/24";
      listenPort = 51820;
      publicEndpoint = "wg.${public.domain}";
    };
    peers = {
      mair = {
        host = "mair";
        address = "10.83.0.10/32";
        publicKey = publicKeys.wireguard.home-mair;
      };
      unifi-travel-router = {
        address = "10.83.0.20/32";
        publicKey = publicKeys.wireguard.home-unifi-travel-router;
      };
    };
  };
}
