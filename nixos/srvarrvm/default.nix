{
  lib,
  config,
  pkgs,
  inputs,
  hostname,
  hostInventory,
  ...
}:
let
  srvarrSpec = hostInventory.nixosHostSpecsByName.srvarr;
  beastNfsAddress = hostInventory.dhcpReservationsByHostname.beast.ip;
  srvarrPorts = {
    aurral = config.systemd.services.aurral.environment.PORT;
    audiobookshelf = config.nixarr.audiobookshelf.port;
    bazarr = config.nixarr.bazarr.port;
    lidarr = config.nixarr.lidarr.port;
    prowlarr = config.nixarr.prowlarr.port;
    radarr = config.nixarr.radarr.port;
    sabnzbd = config.nixarr.sabnzbd.guiPort;
    shelfmark = config.nixarr.shelfmark.port;
    sonarr = config.nixarr.sonarr.port;
    transmission = config.nixarr.transmission.uiPort;
  };
  serviceCatalog = map (
    service:
    if service.scope == "external" then
      service
    else if service.owner == "fana" then
      service
      // {
        url = "http://${service.displayHost}:3000/";
      }
    else
      service
      // {
        url = "http://${service.displayHost}:${toString srvarrPorts.${service.id}}/";
      }
  ) hostInventory.services;
  mediaPath = "/data/media";
  # Resilient NFS client behavior:
  # - hard: block I/O until the server is back (avoid soft I/O errors).
  # - nofail/_netdev/network-online: don't fail boot when NAS is down.
  # - automount + idle timeout: remount on demand after outages.
  # - mount-timeout: fail each mount attempt quickly, retry on next access.
  mediaMountOptions = [
    "nfsvers=4"
    "hard"
    "nofail"
    "_netdev"
    "noatime"
    "x-systemd.automount"
    "x-systemd.idle-timeout=0"
    "x-systemd.mount-timeout=30s"
    "x-systemd.requires=network-online.target"
    "x-systemd.after=network-online.target"
  ];
  media = {
    device = "${beastNfsAddress}:/volume2/Media";
    fsType = "nfs";
    options = mediaMountOptions;
  };
  wgBridgeAddress = srvarrSpec.wgNamespace.bridgeAddress;
  wgNamespaceAddress = srvarrSpec.wgNamespace.namespaceAddress;
  wgConservativeUploadRateMbit = 8;
  wgConservativeUploadRate = "${toString wgConservativeUploadRateMbit}mbit";
  wgConservativeDownloadRateMbit = 400;
  wgConservativeDownloadRate = "${toString wgConservativeDownloadRateMbit}mbit";
  beastNfsRateMbit = 1500;
  beastNfsRate = "${toString beastNfsRateMbit}mbit";
  beastNfsPort = 2049;
  # Keep Transmission a little below the conservative tc floor so
  # Transmission's own scheduler remains the bottleneck and can favor
  # private-tracker torrents before traffic hits the kernel shaper.
  transmissionConservativeUploadLimitKBps = builtins.floor (
    (wgConservativeUploadRateMbit * 1000.0 / 8.0) * 0.95
  );
  wgOuterLinkRate = "10gbit";
  wgEndpointPort = 1637;
  transmissionNonPreferredLowPriorityRatio = 3.0;
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
  wgUnitDepsBase = networkOnlineUnitDeps // {
    After = networkOnlineUnitDeps.After ++ [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
  wgTimerDeps = {
    After = [ "wg.service" ];
  };
  wgUnitDepsWithMount = wgUnitDepsBase // requiresMediaMount;
  requiresMediaMount = networkOnlineUnitDeps // {
    RequiresMountsFor = mediaPath;
  };
  servarrUMask = lib.mkForce "0002";
  isNfsMediaTmpfilesRule =
    rule:
    let
      fields = builtins.filter (field: field != "") (lib.splitString " " rule);
      pathToken = if builtins.length fields > 1 then builtins.elemAt fields 1 else "";
    in
    builtins.any (prefix: lib.hasPrefix prefix pathToken) [
      mediaPath
      "'${mediaPath}"
    ];
  filteredTmpfilesRules = builtins.filter (
    rule: !isNfsMediaTmpfilesRule rule
  ) config.systemd.tmpfiles.rules;
in
{
  _module.args = {
    inherit
      transmissionConservativeUploadLimitKBps
      transmissionNonPreferredLowPriorityRatio
      wgNamespaceAddress
      wgUnitDepsWithMount
      ;
  };

  host.observability.lanWan = {
    interface = "ens18";
    # nft postrouting overcounts the WireGuard transport on this host, so use
    # the shaped tc class as the authoritative WAN egress counter instead.
    wanTransmitTcClass = "1:10";
    wanUdpSubclass = {
      name = "wg";
      port = wgEndpointPort;
    };
  };

  imports = [
    inputs.nixarr.nixosModules.default
    ./aurral.nix
    (import ./adaptive-upload-policy.nix {
      jellyfinExporterUrl = "http://${beastNfsAddress}:9594/metrics";
      fallbackUploadRateMbit = wgConservativeUploadRateMbit;
      inherit
        networkOnlineUnitDeps
        wgEndpointPort
        wgOuterLinkRate
        wgUnitDepsBase
        ;
    })
    ./backup.nix
    ./nightly-speedtest.nix
    ./sabnzbd.nix
    ./sabnzbd-exporter.nix
    ./transmission.nix
    (import ./update-dynamic-ip.nix {
      inherit
        lib
        pkgs
        wgTimerDeps
        wgUnitDepsBase
        ;
    })
    ./transmission-torrent-cleaner.nix
    ./transmission-tracker-prioritizer.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-srvarrvm.yaml;

  # NFS mounts with media
  boot.supportedFilesystems = [ "nfs" ];
  boot.kernelModules = [ "ifb" ];
  services.rpcbind.enable = true;

  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems."${mediaPath}" = media;
  virtualisation.vmVariant.virtualisation.fileSystems."${mediaPath}" = media;
  environment.etc."tmpfiles.d/00-nixos.conf".text = ''
    # This file is created automatically and should not be modified.
    # Please change the option `systemd.tmpfiles.rules` instead.
    # Filtered on srvarr: /data/media is an NFS export managed on beast.

    ${lib.concatStringsSep "\n" filteredTmpfilesRules}
  '';

  users.groups.media.gid = 169;
  users.users.${config.util-nixarr.globals.bazarr.user}.extraGroups = [ "media" ];

  # Service-specific systemd tweaks.
  systemd.services.radarr = {
    serviceConfig.UMask = servarrUMask;
    unitConfig = requiresMediaMount;
  };
  systemd.services.sonarr = {
    serviceConfig.UMask = servarrUMask;
    unitConfig = requiresMediaMount;
  };
  systemd.services.bazarr = {
    serviceConfig.UMask = servarrUMask;
    unitConfig = requiresMediaMount;
  };
  # Make services that r/w to NFS require the media mount.
  systemd.services.audiobookshelf = {
    # nixarr points Audiobookshelf at an absolute data dir under /data, but the
    # upstream module passes that through to StateDirectory=. systemd ignores
    # absolute StateDirectory paths and logs a warning on every unit reload, so
    # clear just that directive and keep the rest of the service as generated.
    serviceConfig.StateDirectory = lib.mkForce null;
    unitConfig = requiresMediaMount;
  };
  systemd.services.seerr.unitConfig = requiresMediaMount;
  systemd.services.lidarr.unitConfig = requiresMediaMount;
  systemd.services.prowlarr.unitConfig = networkOnlineUnitDeps;
  systemd.services.shelfmark.unitConfig = requiresMediaMount;

  nixarr = {
    enable = true;
    vpn = {
      enable = true;
      wgConf = "/data/.secret/vpn/wg.conf";
      accessibleFrom = [
        hostInventory.site.lan.cidr
        "10.0.0.0/8"
      ];
    };

    seerr = {
      enable = true;
      openFirewall = true;
    };
    prowlarr = {
      enable = true;
      openFirewall = true;
    };
    radarr = {
      enable = true;
      openFirewall = true;
    };
    lidarr = {
      enable = true;
      openFirewall = true;
    };
    shelfmark = {
      enable = true;
      host = "0.0.0.0";
      openFirewall = true;
    };
    sonarr = {
      enable = true;
      openFirewall = true;
    };
    bazarr = {
      enable = true;
      openFirewall = true;
    };
    audiobookshelf = {
      enable = true;
      host = "0.0.0.0";
      openFirewall = true;
    };

  };

  # Move VPN bridge off the lab subnet to avoid routing conflicts.
  vpnNamespaces.wg = {
    bridgeAddress = wgBridgeAddress;
    namespaceAddress = wgNamespaceAddress;
  };

  # Apply a conservative bidirectional shaping baseline on the outer interface
  # for WireGuard transport traffic. Also keep NFS writes to beast below the
  # unstable single-flow ceiling observed on this path.
  # The adaptive Jellyfin-aware controller can still raise the WireGuard upload
  # ceiling at runtime when the uplink is otherwise idle.
  systemd.services.wg-qos-upload = {
    wantedBy = [ "multi-user.target" ];
    unitConfig = wgUnitDepsBase;
    serviceConfig =
      let
        wgQosScript = pkgs.writeShellApplication {
          name = "wg-qos-upload";
          runtimeInputs = [
            pkgs.gawk
            pkgs.iproute2
            pkgs.kmod
          ];
          text = ''
            set -euo pipefail

            iface="$(${pkgs.iproute2}/bin/ip -o route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
            ifb_iface="ifb-wg"
            if [ -z "$iface" ]; then
              echo "failed to determine default egress interface" >&2
              exit 1
            fi

            case "''${1:-start}" in
              start)
                ${pkgs.kmod}/bin/modprobe ifb
                ${pkgs.iproute2}/bin/ip link add "$ifb_iface" type ifb 2>/dev/null || true
                ${pkgs.iproute2}/bin/ip link set dev "$ifb_iface" up

                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" root handle 1: htb default 20 r2q 1000
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1: classid 1:1 htb rate ${wgOuterLinkRate} ceil ${wgOuterLinkRate}
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:10 htb rate ${wgConservativeUploadRate} ceil ${wgConservativeUploadRate}
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:15 htb rate ${beastNfsRate} ceil ${beastNfsRate}
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:20 htb rate ${wgOuterLinkRate} ceil ${wgOuterLinkRate}
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:10 handle 10: cake bandwidth ${wgConservativeUploadRate} besteffort wash
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:15 handle 15: fq_codel
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:20 handle 20: fq_codel
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" protocol ip parent 1: prio 10 flower ip_proto udp dst_port ${toString wgEndpointPort} classid 1:10
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" protocol ipv6 parent 1: prio 11 flower ip_proto udp dst_port ${toString wgEndpointPort} classid 1:10
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" protocol ip parent 1: prio 15 flower ip_proto tcp dst_ip ${beastNfsAddress} dst_port ${toString beastNfsPort} classid 1:15

                ${pkgs.iproute2}/bin/tc qdisc del dev "$ifb_iface" root 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc add dev "$ifb_iface" root cake bandwidth ${wgConservativeDownloadRate} besteffort wash ingress

                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" ingress 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" handle ffff: ingress
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" parent ffff: protocol ip prio 10 flower ip_proto udp src_port ${toString wgEndpointPort} action mirred egress redirect dev "$ifb_iface"
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" parent ffff: protocol ipv6 prio 11 flower ip_proto udp src_port ${toString wgEndpointPort} action mirred egress redirect dev "$ifb_iface"
                ;;
              stop)
                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" ingress 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root || true
                ${pkgs.iproute2}/bin/tc qdisc del dev "$ifb_iface" root 2>/dev/null || true
                ${pkgs.iproute2}/bin/ip link set dev "$ifb_iface" down 2>/dev/null || true
                ${pkgs.iproute2}/bin/ip link delete dev "$ifb_iface" type ifb 2>/dev/null || true
                ;;
              *)
                echo "usage: $0 [start|stop]" >&2
                exit 2
                ;;
            esac
          '';
        };
      in
      {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe wgQosScript} start";
        ExecStop = "${lib.getExe wgQosScript} stop";
      };
  };

  services.glance = {
    enable = true;
    openFirewall = true;
    settings = {
      server = {
        host = "0.0.0.0";
        port = 80;
      };
      pages = [
        {
          name = "Startpage";
          width = "slim";
          hide-desktop-navigation = true;
          center-vertically = true;
          columns = [
            {
              size = "full";
              widgets = [
                {
                  type = "search";
                  autofocus = true;
                }
                {
                  type = "monitor";
                  cache = "1m";
                  title = "Services";
                  sites = map (service: {
                    inherit (service)
                      icon
                      title
                      url
                      ;
                  }) serviceCatalog;
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # Allow glance to bind to lower port, 80
  systemd.services.glance.serviceConfig = {
    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    NoNewPrivileges = false;
    PrivateUsers = lib.mkForce false;
  };
}
