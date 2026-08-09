{
  context,
  lib,
}:
let
  inherit (context) frame lanDomain;

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
      isBuilder = true;
      isVM = true;
      observability.capacityProfile = "cpu-bursty";
      name = "builder${idx'}";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      proxNode = "prx${idx'}-lab";
      dhcpReservation = builderDhcpReservations.${idx'};
      memorySize = 64;
      balloonSize = 48;
      diskSize = 150;
      cores = 24;
      hmFull = false;
      nspawnTestBuilder = true;
    };

  labProxmoxSpec =
    {
      index,
      macAddress,
      proxmoxUpgradeTime,
    }:
    let
      index' = toString index;
      name = "prx${index'}-lab";
      ipAddress = "192.168.15.${toString (index + 9)}";
    in
    {
      hostKind = "proxmox";
      inherit
        ipAddress
        macAddress
        name
        proxmoxUpgradeTime
        ;
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      hmFull = false;
      observability.capacityProfile = "hypervisor";
      dhcpReservation = {
        match = macAddress;
        ip = ipAddress;
      };
    }
    // lib.optionalAttrs (index == 1) {
      dnsAliases = [ "proxmox.${lanDomain}" ];
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
      platform = "aarch64-darwin";
      realm = "home";
      userProfile = "personal";
      availability = "intermittent";
      observability.capacityProfile = "interactive";
      hasTouchId = true;
      isDesktop = true;
      isOperatorSeat = true;
      isSecretsOperator = true;
      lanWanInterfaces = [ "en0" ];
    };
    mmini = {
      platform = "aarch64-darwin";
      realm = "home";
      userProfile = "personal";
      isBuilder = true;
      observability = {
        capacityProfile = "interactive";
        thermalProfile = "no-cpu";
      };
      isDesktop = true;
      isOperatorSeat = true;
      isSecretsOperator = true;
      lanWanInterfaces = [ "en0" ];
    };
    JGWXHWDL4X = {
      platform = "aarch64-darwin";
      realm = "work";
      userProfile = "nvidia";
      availability = "intermittent";
      hasTouchId = true;
      isDesktop = true;
      isOperatorSeat = true;
      isSecretsOperator = true;
      lanWanInterfaces = [
        "en0"
        "en7"
      ];
    };
  };

  nixosHostSpecs = [
    {
      hostKind = "nixos";
      name = frame;
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      isBuilder = true;
      observability.capacityProfile = "cpu-bursty";
      isDesktop = true;
      isOperatorSeat = true;
      isSecretsOperator = true;
      nspawnTestBuilder = true;
      sshTicket.allowX11Forwarding = true;
      hardware =
        let
          displayMode = {
            width = 3840;
            height = 2160;
            refreshRate = 60;
          };
          displayScale = 1.5;
          logicalDisplayWidth = builtins.floor (displayMode.width / displayScale);
          mkDisplay =
            {
              name,
              connector,
              x,
              primary ? false,
            }:
            let
              y = 0;
            in
            {
              inherit
                connector
                name
                primary
                ;
              scale = displayScale;
              mode = displayMode;
              logical = {
                inherit x y;
                width = logicalDisplayWidth;
                height = builtins.floor (displayMode.height / displayScale);
              };
            };
        in
        {
          # Shared display topology for the kernel, GDM, Hyprland, and ReFrame.
          drmCard = "card1";
          displays = [
            (mkDisplay {
              name = "left";
              connector = "DP-4";
              x = 0;
              primary = true;
            })
            (mkDisplay {
              name = "right";
              connector = "DP-2";
              x = logicalDisplayWidth;
            })
          ];
        };
      dhcpReservation = {
        match = "9c:bf:0d:00:fa:0a";
        ip = "192.168.11.228";
      };
    }
    {
      hostKind = "proxmox";
      name = "nvws";
      platform = "x86_64-linux";
      realm = "work";
      userProfile = "nvidia";
      isBuilder = true;
      nspawnTestBuilder = true;
      hmFull = false;
      ipAddress = "192.168.15.100";
      macAddress = "ac:b4:80:40:05:2e";
      dhcpReservation = {
        match = "ac:b4:80:40:05:2e";
        ip = "192.168.15.100";
      };
    }
    {
      hostKind = "nixos";
      name = "beast";
      platform = "x86_64-linux";
      realm = "home";
      userProfile = "personal";
      critical = true;
      hmFull = false;
      hardware.igpu.renderDevice = "/dev/dri/renderD128";
      dhcpReservation = {
        match = "bc:fc:e7:3b:fe:da";
        ip = "192.168.16.3";
      };
    }
    (labProxmoxSpec {
      index = 1;
      proxmoxUpgradeTime = "Mon 03:50";
      macAddress = "38:05:25:30:7d:89";
    })
    (labProxmoxSpec {
      index = 2;
      proxmoxUpgradeTime = "Mon 04:20";
      macAddress = "38:05:25:30:7f:7d";
    })
    (labProxmoxSpec {
      index = 3;
      proxmoxUpgradeTime = "Mon 04:50";
      macAddress = "38:05:25:30:7d:69";
    })
    {
      isVM = true;
      name = "nv";
      platform = "x86_64-linux";
      realm = "work";
      userProfile = "nvidia";
      isOperatorSeat = true;
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
      localDnsAliases = [ "nix-cache" ];
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
      wgNamespace = {
        bridgeAddress = "192.168.50.5";
        namespaceAddress = "192.168.50.1";
        # Ports allocated in AirVPN's forwarded-port control panel.
        forwardedPorts = {
          slskd = 13869;
          transmission = 45486;
        };
      };
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
      caServer = {
        port = 8443;
        # Fixed step-ca HTTP API route for the trusted root bundle.
        rootsPath = "/roots.pem";
      };
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
  ++ map builderSpec [
    1
    2
    3
  ];
}
