{
  attic,
  lanDomain,
  publicDomain,
  readPublicKey,
}:
let
  nixCacheUrlWithPriority = url: priority: "${url}?priority=${toString priority}";
in
rec {
  public = {
    domain = publicDomain;
  };

  links = {
    internet = { };
    lan = { };
  };

  dynamicDns.freeDns = {
    username = "ihrachyshka";
    records = {
      beast = "ihrachyshka-beast.freeddns.org";
      gw = "ihrachyshka-gw.freeddns.org";
    };
  };

  ports = {
    watchstate = 8080;
  };

  nixCaches =
    let
      flakehubUrl = "https://cache.flakehub.com";
    in
    {
      nixos = {
        url = "https://cache.nixos.org/";
        key = readPublicKey ../public-keys/nix-cache/nixos.pub;
      };
      home = {
        url = attic.substituterUrl;
        key = readPublicKey ../public-keys/nix-cache/home.pub;
        defaultUrl = nixCacheUrlWithPriority attic.substituterUrl 30;
        lanUrl = nixCacheUrlWithPriority attic.substituterUrl 10;
        vpnUrl = nixCacheUrlWithPriority attic.substituterUrl 30;
      };
      flakehub = {
        url = flakehubUrl;
        lanUrl = nixCacheUrlWithPriority flakehubUrl 30;
        vpnUrl = nixCacheUrlWithPriority flakehubUrl 10;
      };
    };

  lan = {
    cidr = "192.168.0.0/16";
    domain = lanDomain;
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
      dynamicDnsRecord = "gw";
      qos.uploadLimitMbit = 10;
    };
    peers = {
      mair = {
        host = "mair";
        address = "10.83.0.10/32";
        publicKey = readPublicKey ../public-keys/wireguard/home-mair.pub;
      };
      unifi-travel-router = {
        address = "10.83.0.20/32";
        publicKey = readPublicKey ../public-keys/wireguard/home-unifi-travel-router.pub;
      };
    };
  };
}
