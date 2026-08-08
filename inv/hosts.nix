{
  frame,
  lib,
}:
{
  lanDomain,
  publicDomain,
  publicServiceHosts,
}:
let
  prxStateVersion = "25.11";
  prxNetIface = "enp5s0f0np0";
  nvws = "nvws";

  builderDhcpReservations = {
    "1" = {
      match = "bc:24:11:49:bf:fc";
      ip = "192.168.12.106";
    };
    "2" = {
      match = "bc:24:11:dc:ea:2c";
      ip = "192.168.13.243";
    };
    "3" = {
      match = "bc:24:11:2a:ee:d7";
      ip = "192.168.11.114";
    };
  };

  builderSpec =
    idx:
    let
      idx' = toString idx;
    in
    {
      builder.pool = "personal";
      isVM = true;
      name = "builder${idx'}";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      proxNode = "prx${idx'}-lab";
      dhcpReservation = builderDhcpReservations.${idx'};
      stateVersion = "25.11";
      memorySize = 64;
      balloonSize = 48;
      diskSize = 150;
      cores = 24;
      hmFull = false;
    };

  labProxmoxSpec =
    {
      index,
      macAddress,
    }:
    let
      index' = toString index;
      name = "prx${index'}-lab";
      ipAddress = "192.168.15.${toString (index + 9)}";
    in
    {
      inherit
        ipAddress
        macAddress
        name
        ;
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      hmFull = false;
      stateVersion = prxStateVersion;
      network.primaryInterface = prxNetIface;
      dhcpReservation = {
        match = macAddress;
        ip = ipAddress;
      };
    }
    // lib.optionalAttrs (index == 1) {
      dnsAliases = [ "proxmox.${lanDomain}" ];
    }
    // lib.optionalAttrs (index != 1) {
      upsHost = "prx1-lab";
    };
in
{
  staticDhcpReservations = [
    {
      identifiers = [ "7c:b7:7b:04:05:99" ];
      hostname = "mdx";
      ip = "192.168.10.100";
    }
    {
      identifiers = [ "06:b5:a3:b9:6b:e0" ];
      hostname = "mlt";
      ip = "192.168.11.2";
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

  darwinHosts = lib.mapAttrs (name: spec: spec // { inherit name; }) {
    mair = {
      stateVersion = 6;
      hmStateVersion = "25.11";
      platform = "aarch64-darwin";
      realm = "home";
      userProfile = "personal";
      availability = "intermittent";
      hasTouchId = true;
      isDesktop = true;
      isOperatorSeat = true;
      isSecretsOperator = true;
      remoteGui = {
        server.vnc.enable = true;
        client = {
          x11.enable = true;
          wayland.enable = true;
          vnc.enable = true;
        };
      };
      network.primaryInterface = "en0";
    };
    mmini = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      platform = "aarch64-darwin";
      realm = "home";
      userProfile = "personal";
      builder.pool = "personal";
      isDesktop = true;
      isOperatorSeat = true;
      isSecretsOperator = true;
      remoteGui = {
        server.vnc.enable = true;
        client = {
          x11.enable = true;
          vnc.enable = true;
        };
      };
      upsHost = frame;
      network.primaryInterface = "en0";
    };
    JGWXHWDL4X = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      platform = "aarch64-darwin";
      realm = "work";
      userProfile = "nvidia";
      availability = "intermittent";
      hasTouchId = true;
      isDesktop = true;
      isOperatorSeat = true;
      isSecretsOperator = true;
      network = {
        manageIdentity = false;
        primaryInterface = "en0";
        lanWanInterfaces = [
          "en0"
          "en7"
        ];
      };
    };
  };

  nixosHostSpecs = [
    {
      name = frame;
      stateVersion = "25.11";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      builder = {
        pool = "personal";
        speedFactor = 200;
      };
      desktop.environment = "hyprland";
      isOperatorSeat = true;
      isSecretsOperator = true;
      boot.remoteUnlock = {
        enable = true;
        interface = "enp191s0";
        kernelModules = [ "r8169" ];
      };
      remoteGui.server = {
        x11.enable = true;
        wayland.enable = true;
        vnc = {
          enable = true;
          # ReFrame exposes one loopback listener per inventory display.
          sshTunnel = true;
          basePort = 5933;
        };
      };
      hardware.gpu = {
        vendor = "amd";
        computeBackend = "rocm";
      };
      dhcpReservation = {
        match = "9c:bf:0d:00:fa:0a";
        ip = "192.168.11.228";
      };
    }
    {
      name = nvws;
      platform = "x86_64-linux";
      realm = "work";
      userProfile = "nvidia";
      builder = {
        pool = "work";
        sshHost = "nvws.local";
      };
      hmFull = false;
      stateVersion = "25.11";
      network.primaryInterface = "enp3s0f0";
      ipAddress = "192.168.15.100";
      macAddress = "ac:b4:80:40:05:2e";
      dhcpReservation = {
        match = "ac:b4:80:40:05:2e";
        ip = "192.168.15.100";
      };
    }
    {
      name = "beast";
      stateVersion = "25.11";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      autoUpgrade.rebootPolicy = "weekly-if-needed";
      dnsAliases = builtins.filter (domain: domain != "dash.${publicDomain}") publicServiceHosts;
      hmFull = false;
      network = {
        primaryInterface = "enp6s0";
        # Links on the TL2-F7120 can drop intermittently with pause frames.
        # Flow control is also disabled on these switch ports.
        pauseDisabledInterfaces = [
          "enp6s0"
          "enp7s0"
        ];
      };
      hardware.gpu = {
        vendor = "intel";
        videoAcceleration = {
          backend = "qsv";
          device = "/dev/dri/renderD128";
        };
      };
      dhcpReservation = {
        match = "bc:fc:e7:3b:fe:da";
        ip = "192.168.16.3";
      };
    }
    (labProxmoxSpec {
      index = 1;
      macAddress = "38:05:25:30:7d:89";
    })
    (labProxmoxSpec {
      index = 2;
      macAddress = "38:05:25:30:7f:7d";
    })
    (labProxmoxSpec {
      index = 3;
      macAddress = "38:05:25:30:7d:69";
    })
    {
      isVM = true;
      name = "nv";
      platform = "x86_64-linux";
      realm = "work";
      userProfile = "nvidia";
      isOperatorSeat = true;
      stateVersion = "25.11";
      upsHost = nvws;
      dhcpReservation = {
        match = "bc:24:11:ed:30:d3";
        ip = "192.168.10.138";
      };
      cores = 64;
      memorySize = 128;
      sshPort = 10000;
      proxNode = "nvws";
    }
    {
      isVM = true;
      name = "cache";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      stateVersion = "25.11";
      upsHost = "prx1-lab";
      dhcpReservation = {
        match = "bc:24:11:0d:85:41";
        ip = "192.168.20.7";
      };
      sshPort = 10004;
      hmFull = false;
      cores = 16;
      memorySize = 16;
      diskSize = 50; # actual cache is on NFS
    }
    {
      isVM = true;
      name = "srvarr";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      stateVersion = "25.11";
      upsHost = "prx1-lab";
      dnsAliases = [ "dash.${publicDomain}" ];
      cores = 16;
      memorySize = 32;
      sshPort = 10005;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:19:4d:d1";
        ip = "192.168.20.2";
      };
    }
    {
      isVM = true;
      name = "fana";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      stateVersion = "25.11";
      upsHost = "prx1-lab";
      cores = 8;
      memorySize = 16;
      diskSize = 300;
      sshPort = 10006;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:06:e8:8b";
        ip = "192.168.13.110";
      };
    }
    {
      isVM = true;
      name = "gw";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      stateVersion = "25.11";
      upsHost = "prx1-lab";
      cores = 2;
      memorySize = 8;
      diskSize = 64;
      sshPort = 10008;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:91:b5:77";
        ip = "192.168.20.3";
      };
    }
    {
      isVM = true;
      name = "org";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      stateVersion = "25.11";
      upsHost = "prx1-lab";
      cores = 4;
      memorySize = 16;
      diskSize = 80;
      sshPort = 10009;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:fd:eb:9c";
        ip = "192.168.20.4";
      };
    }
    {
      isVM = true;
      name = "pki";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      stateVersion = "25.11";
      upsHost = "prx1-lab";
      cores = 2;
      memorySize = 4;
      diskSize = 50;
      sshPort = 10010;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:c6:ab:fc";
        ip = "192.168.20.5";
      };
    }
    {
      isVM = true;
      name = "home";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      stateVersion = "26.05";
      upsHost = "prx1-lab";
      proxNode = "prx2-lab";
      cores = 4;
      memorySize = 8;
      diskSize = 80;
      sshPort = 10011;
      hmFull = false;
      dhcpReservation = {
        match = "02:48:4f:4d:45:01";
        ip = "192.168.20.6";
      };
    }
  ]
  ++ map (idx: (builderSpec idx) // { upsHost = "prx1-lab"; }) [
    1
    2
    3
  ];
}
