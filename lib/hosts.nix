{
  lib,
  username ? "ihrachyshka",
}:
let
  prxStateVersion = "25.11";
  prxNetIface = "enp5s0f0np0";
  prxPassword = "$6$CfXpVD4RDVuPrP1r$sQ8DQgErhyPNmVsRB0cJPwiF/UM3yFC2ZTYRCdtrBAYQXG63GlnLIyOc5vZ2jswJb66KGwitwErNXmUnBWy0R.";

  piStateVersion = "25.11";
  piHostname = "pi5";

  frame = "frame";
  nvws = "nvws";

  builderSpec =
    idx:
    let
      idx' = toString idx;
    in
    {
      type = "vm";
      name = "builder${idx'}";
      proxNode = "prx${idx'}-lab";
      stateVersion = "25.11";
      memorySize = 64;
      diskSize = 150;
      cores = 24;
      hmFull = false;
    };
in
rec {
  virtPlatform = "aarch64-darwin";

  toVmName = name: "${name}vm";
  toUpsName = name: "${lib.strings.toUpper name}-UPS";

  site = {
    lan = {
      cidr = "192.168.0.0/16";
      domain = "home.arpa";
      upstreamGateway = "192.168.0.1";
      gateway = {
        host = piHostname;
        address = "192.168.1.1";
      };
      guest = {
        host = piHostname;
        address = "192.168.2.1";
      };
      dhcpRanges = {
        main = {
          excludeRanges = [
            # nixarr still assumes 192.168.15.0/24 for its WireGuard-facing proxy.
            "192.168.15.0/24"
            # Reserve the VPN netns subnet for srvarr's local wg bridge.
            "192.168.50.0/24"
          ];
          ranges = [
            {
              start = "192.168.10.1";
              end = "192.168.14.255";
            }
            {
              start = "192.168.16.1";
              end = "192.168.20.255";
            }
          ];
        };
        guest = {
          excludeRanges = [ ];
          ranges = [
            {
              start = "192.168.100.1";
              end = "192.168.100.255";
            }
          ];
        };
      };
    };

    wireguard.home = {
      cidr = "10.83.0.0/24";
      gateway = {
        host = "gw";
        address = "10.83.0.1/24";
        listenPort = 51820;
        publicEndpoint = "wg.ihar.dev";
      };
      peers = {
        mair = {
          host = "mair";
          address = "10.83.0.10/32";
        };
      };
    };
  };

  staticDhcpReservations = [
    {
      identifiers = [ "7c:b7:7b:04:05:99" ];
      hostname = "mdx";
      ip = "192.168.10.100";
    }
    {
      identifiers = [ "id:JGWXHWDL4X" ];
      hostname = "mlt";
      ip = "192.168.11.2";
    }
    {
      identifiers = [
        "a2:65:a0:ce:9f:23"
        "id:mair"
      ];
      hostname = "mair";
      ip = "192.168.11.3";
    }
    {
      identifiers = [ "78:2d:7e:24:2d:f9" ];
      hostname = "sw-lab";
      ip = "192.168.15.1";
    }
    {
      identifiers = [ "bc:fc:e7:3b:f5:99" ];
      hostname = "beast-ipmi";
      ip = "192.168.16.4";
    }
  ];

  darwinHosts = {
    mair = {
      stateVersion = 6;
      hmStateVersion = "25.11";
      hostname = "mair";
      platform = "aarch64-darwin";
      isDesktop = true;
    };
    mmini = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      hostname = "mmini";
      platform = "aarch64-darwin";
      isDesktop = true;
    };
    JGWXHWDL4X = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      hostname = "JGWXHWDL4X";
      platform = "aarch64-darwin";
      isDesktop = true;
      isWork = true;
    };
  };

  nixosHostSpecs = [
    {
      type = "bm";
      hostKind = "raspberryPi";
      name = piHostname;
      dnsName = "dhcp";
      upsMonitorName = "pi5";
      stateVersion = piStateVersion;
      homeManagerInput = "home-manager-25_11";
      hmFull = false;
    }
    {
      type = "bm";
      hostKind = "nixos";
      name = frame;
      password = "$6$yJXP9KwAM7LaQrtn$K5ybpfl1xxjRTRMXj6CxSFspEdDcWeEVzhc6Wq0PX7G/y9Tvt1QWq5F6ycR0wy4TseTXeom9DdzK4XrBwym2Q/";
      stateVersion = "25.11";
      platform = "x86_64-linux";
      isDesktop = true;
    }
    {
      type = "bm";
      hostKind = "proxmox";
      name = nvws;
      inherit username;
      isWork = true;
      upsHost = piHostname;
      password = "$6$zoSR/.ZJMjOtERiO$Dm3aOpCiAMRlHT/SQ2mzIANa2zGZNUq2Iwuh35BTS.TtaTaKh7Y0aNxP4lxrsfXtcykMNhadUgMwXgf2c/7pz0";
      stateVersion = "25.11";
      netIface = "enp3s0f0";
      ipAddress = "192.168.15.100";
      macAddress = "ac:b4:80:40:05:2e";
      dhcpReservation = {
        match = "ac:b4:80:40:05:2e";
        hostname = "nvws";
        ip = "192.168.15.100";
      };
    }
    {
      type = "bm";
      hostKind = "nixos";
      name = "beast";
      stateVersion = "25.11";
      platform = "x86_64-linux";
      nixpkgsInput = "nixpkgs-25_11";
      homeManagerInput = "home-manager-25_11";
      hmFull = false;
      dhcpReservation = {
        match = "id:beast";
        hostname = "beast";
        ip = "192.168.16.3";
      };
    }
    {
      type = "bm";
      hostKind = "proxmox";
      name = "prx1-lab";
      inherit username;
      password = prxPassword;
      upsMonitorName = "nas";
      stateVersion = prxStateVersion;
      netIface = prxNetIface;
      ipAddress = "192.168.15.10";
      macAddress = "38:05:25:30:7d:89";
      dhcpReservation = {
        match = "38:05:25:30:7d:89";
        hostname = "prx1-lab";
        ip = "192.168.15.10";
      };
    }
    {
      type = "bm";
      hostKind = "proxmox";
      name = "prx2-lab";
      inherit username;
      upsHost = "prx1-lab";
      password = prxPassword;
      stateVersion = prxStateVersion;
      netIface = prxNetIface;
      ipAddress = "192.168.15.11";
      macAddress = "38:05:25:30:7f:7d";
      dhcpReservation = {
        match = "38:05:25:30:7f:7d";
        hostname = "prx2-lab";
        ip = "192.168.15.11";
      };
    }
    {
      type = "bm";
      hostKind = "proxmox";
      name = "prx3-lab";
      inherit username;
      upsHost = "prx1-lab";
      password = prxPassword;
      stateVersion = prxStateVersion;
      netIface = prxNetIface;
      ipAddress = "192.168.15.12";
      macAddress = "38:05:25:30:7d:69";
      dhcpReservation = {
        match = "38:05:25:30:7d:69";
        hostname = "prx3-lab";
        ip = "192.168.15.12";
      };
    }
    {
      type = "vm";
      name = "nv";
      isWork = true;
      upsHost = piHostname;
      cores = 64;
      memorySize = 128;
      sshPort = 10000;
      proxNode = "nvws";
    }
    {
      type = "vm";
      name = "cache";
      upsHost = "prx1-lab";
      sshPort = 10004;
      hmFull = false;
      cores = 16;
      memorySize = 16;
      diskSize = 50; # actual cache is on NFS
    }
    {
      type = "vm";
      name = "srvarr";
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
      cores = 16;
      memorySize = 32;
      sshPort = 10005;
      hmFull = false;
      dhcpReservation = {
        match = "id:prox-srvarrvm";
        hostname = "prox-srvarrvm";
        ip = "192.168.20.2";
      };
    }
    {
      type = "vm";
      name = "fana";
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
      cores = 8;
      memorySize = 16;
      diskSize = 300;
      sshPort = 10006;
      hmFull = false;
    }
    {
      type = "vm";
      name = "desk";
      upsHost = "prx1-lab";
      cores = 4;
      memorySize = 12;
      diskSize = 80;
      sshPort = 10007;
      hmFull = false;
    }
    {
      type = "vm";
      name = "gw";
      upsHost = "prx1-lab";
      cores = 2;
      memorySize = 8;
      diskSize = 64;
      sshPort = 10008;
      hmFull = false;
      dhcpReservation = {
        match = "id:prox-gwvm";
        hostname = "prox-gwvm";
        ip = "192.168.20.3";
      };
    }
    {
      type = "vm";
      name = "org";
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
      cores = 4;
      memorySize = 8;
      diskSize = 80;
      sshPort = 10009;
      hmFull = false;
      dhcpReservation = {
        match = "id:prox-orgvm";
        hostname = "prox-orgvm";
        ip = "192.168.20.4";
      };
    }
  ]
  ++ map (idx: (builderSpec idx) // { upsHost = "prx1-lab"; }) [
    1
    2
    3
  ];

  managedDhcpReservations = map (
    spec: spec.dhcpReservation
  ) (builtins.filter (spec: spec ? dhcpReservation) nixosHostSpecs);

  dhcpReservationsByHostname = builtins.listToAttrs (
    map (
      reservation: {
        name = reservation.hostname;
        value = reservation;
      }
    ) (managedDhcpReservations ++ staticDhcpReservations)
  );

  nixosHostSpecsByName = builtins.listToAttrs (
    map (spec: {
      name = spec.name;
      value = spec;
    }) nixosHostSpecs
  );
}
