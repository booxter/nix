{
  frame,
  lib,
  username,
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
      isBuilder = true;
      isVM = true;
      name = "builder${idx'}";
      platform = "x86_64-linux";
      proxNode = "prx${idx'}-lab";
      dhcpReservation = builderDhcpReservations.${idx'};
      stateVersion = "25.11";
      memorySize = 64;
      balloonSize = 48;
      diskSize = 150;
      cores = 24;
      hmFull = false;
      nspawnTestBuilder = true;
      resourceControl.diskSwapGiB = 8;
      extraModules = [
        (
          {
            hostname,
            hostSpecName ? hostname,
            lib,
            ...
          }:
          {
            system.autoUpgrade = lib.mkIf (lib.hasPrefix "builder" hostSpecName) {
              dates = "Mon 03:00";
              rebootWindow = {
                lower = lib.mkForce "02:59";
                upper = lib.mkForce "06:00";
              };
            };
          }
        )
      ];
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
        username
        ;
      platform = "x86_64-linux";
      hmFull = false;
      stateVersion = prxStateVersion;
      netIface = prxNetIface;
      hardware.gpuFamilies = [ "intel" ];
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
      isDesktop = true;
      isLaptop = true;
      vnc.enable = true;
      hardware.gpuFamilies = [ "apple" ];
      lanWanInterfaces = [ "en0" ];
    };
    mmini = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      platform = "aarch64-darwin";
      isBuilder = true;
      isDesktop = true;
      vnc.enable = true;
      hardware.gpuFamilies = [ "apple" ];
      upsHost = frame;
      lanWanInterfaces = [ "en0" ];
    };
    JGWXHWDL4X = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      platform = "aarch64-darwin";
      isDesktop = true;
      isLaptop = true;
      isWork = true;
      hardware.gpuFamilies = [ "apple" ];
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
      stateVersion = "25.11";
      platform = "x86_64-linux";
      isBuilder = true;
      isDesktop = true;
      nspawnTestBuilder = true;
      sshTicket.allowX11Forwarding = true;
      resourceControl.diskSwapGiB = 8;
      resourceControl.systemServices = {
        lightweight = [
          "fana-alertmanager-watchdog"
          "frame-amdgpu-metrics"
          "frame-ollama-metrics"
          "ollama-model-loader"
          "prometheus-blackbox-exporter"
          "prometheus-node-exporter"
        ];
        heavy.ollama = {
          memoryHigh = "80%";
          memoryMax = "90%";
          memorySwapMax = "8G";
          tasksMax = 4096;
        };
      };
      resourceControl.userServices.lightweight = [
        "codex-warmer"
        "gmailctl-token-keepalive"
        "sync-git-mains"
      ];
      vnc = {
        enable = true;
        # ReFrame exposes one loopback listener per inventory display.
        sshTunnel = true;
        basePort = 5933;
      };
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
          gpuFamilies = [ "amd" ];
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
      name = nvws;
      platform = "x86_64-linux";
      inherit username;
      isBuilder = true;
      isWork = true;
      hmFull = false;
      stateVersion = "25.11";
      netIface = "enp3s0f0";
      ipAddress = "192.168.15.100";
      macAddress = "ac:b4:80:40:05:2e";
      hardware.gpuFamilies = [ "nvidia" ];
      dhcpReservation = {
        match = "ac:b4:80:40:05:2e";
        ip = "192.168.15.100";
      };
    }
    {
      hostKind = "nixos";
      name = "beast";
      stateVersion = "25.11";
      platform = "x86_64-linux";
      critical = true;
      dnsAliases = builtins.filter (domain: domain != "dash.${publicDomain}") publicServiceHosts;
      resourceControl.diskSwapGiB = 8;
      resourceControl.systemServices = {
        lightweight = [
          "beast-disk-bay-export"
          "beast-hba-export"
          "beast-md-sync-export"
          "jellarr"
          "jellyfin-exporter"
          "prometheus-node-exporter"
          "prometheus-smartctl-exporter"
          "restic-cloud-usage-export"
        ];
        critical = [
          "jellyfin"
          "nfs-server"
        ];
      };
      hmFull = false;
      hardware.gpuFamilies = [ "intel" ];
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
      isWork = true;
      upsHost = nvws;
      dhcpReservation = {
        match = "bc:24:11:ed:30:d3";
        ip = "192.168.10.138";
      };
      cores = 64;
      memorySize = 128;
      sshPort = 10000;
      proxNode = "nvws";
      resourceControl.diskSwapGiB = 8;
    }
    {
      isVM = true;
      name = "cache";
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
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
      resourceControl.diskSwapGiB = 4;
    }
    {
      isVM = true;
      name = "srvarr";
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
      dnsAliases = [ "dash.${publicDomain}" ];
      wgNamespace = {
        bridgeAddress = "192.168.50.5";
        namespaceAddress = "192.168.50.1";
        # Ports allocated in AirVPN's forwarded-port control panel.
        forwardedPorts = {
          slskd = 13869;
          transmission = 45486;
        };
      };
      resourceControl.systemServices = {
        lightweight = [
          "audiobookshelf-backup-bootstrap"
          "audiobookshelf-oidc-bootstrap"
          "houndarr-status-collector"
          "jellyfin-upload-policy"
          "jellyfin-upload-policy-tc"
          "jellyfin-upload-policy-transmission"
          "letterboxd-list-radarr"
          "prometheus-node-exporter"
          "prometheus-sabnzbd-exporter"
          "transmission-collector"
          "transmission-prioritizer"
          "transmission-torrent-cleaner"
          "update-dynamic-ip"
          "wg-bridge-access"
          "wg-qos"
        ];
        medium = [
          "ebook-converter"
          "lidarr-cue-splitter"
        ];
      };
      cores = 16;
      memorySize = 32;
      resourceControl.diskSwapGiB = 4;
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
      upsHost = "prx1-lab";
      resourceControl.systemServices = {
        lightweight = [
          "prometheus-blackbox-exporter"
          "prometheus-node-exporter"
          "prometheus-nut-exporter"
          "unpoller"
        ];
        critical = [ "alertmanager" ];
      };
      cores = 8;
      memorySize = 16;
      diskSize = 300;
      resourceControl.diskSwapGiB = 4;
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
      upsHost = "prx1-lab";
      resourceControl.systemServices.lightweight = [
        "prometheus-node-exporter"
        "prometheus-wireguard-exporter"
        "wg-qos"
      ];
      cores = 2;
      memorySize = 8;
      diskSize = 64;
      resourceControl.diskSwapGiB = 2;
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
      resourceControl.systemServices.lightweight = [
        "prometheus-node-exporter"
        "prometheus-paperless-exporter"
      ];
      upsHost = "prx1-lab";
      cores = 4;
      memorySize = 16;
      diskSize = 80;
      resourceControl.diskSwapGiB = 4;
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
      caServer = {
        port = 8443;
        # Fixed step-ca HTTP API route for the trusted root bundle.
        rootsPath = "/roots.pem";
      };
      resourceControl.systemServices = {
        lightweight = [
          "kanidm-mail-sender"
          "kanidm-mail-sender-bootstrap"
          "kanidm-oidc-probe-bootstrap"
          "kanidm-oidc-synthetic-probe"
          "kanidm-person-mail-provision"
          "pki-rotate"
          "pki-status-export"
          "prometheus-node-exporter"
          "unifi-sync"
          "uptimerobot-sync"
          "wg-home-dns-sync"
        ];
        critical = [
          "kanidm"
          "step-ca"
        ];
      };
      upsHost = "prx1-lab";
      cores = 2;
      memorySize = 4;
      diskSize = 50;
      resourceControl.diskSwapGiB = 2;
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
      stateVersion = "26.05";
      upsHost = "prx1-lab";
      proxNode = "prx2-lab";
      resourceControl.systemServices = {
        lightweight = [
          "home-assistant-bootstrap"
          "home-assistant-native-backup"
          "prometheus-node-exporter"
        ];
        critical = [ "home-assistant" ];
      };
      cores = 4;
      memorySize = 8;
      diskSize = 80;
      resourceControl.diskSwapGiB = 2;
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
