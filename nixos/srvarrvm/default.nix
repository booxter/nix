{
  lib,
  config,
  pkgs,
  inputs,
  hostname,
  ...
}:
let
  arrServices = import ../../lib/arr-services.nix {
    srvarrDisplayHost = "${config.services.avahi.hostName}.local";
    srvarrPorts = {
      audiobookshelf = config.nixarr.audiobookshelf.port;
      bazarr = config.nixarr.bazarr.port;
      lidarr = config.nixarr.lidarr.port;
      prowlarr = config.nixarr.prowlarr.port;
      radarr = config.nixarr.radarr.port;
      readarr = config.nixarr.readarr.port;
      readarrAudio = config.nixarr.readarr-audiobook.port;
      sabnzbd = config.nixarr.sabnzbd.guiPort;
      sonarr = config.nixarr.sonarr.port;
      transmission = config.nixarr.transmission.uiPort;
    };
  };
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
    device = "beast:/volume2/Media";
    fsType = "nfs";
    options = mediaMountOptions;
  };
  wgBridgeAddress = "192.168.50.5";
  wgNamespaceAddress = "192.168.50.1";
  wgUploadRate = "8mbit";
  wgOuterLinkRate = "10gbit";
  wgEndpointPort = 1637;
  wgUnitDepsBase = {
    After = [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
  wgUnitDepsWithMount = wgUnitDepsBase // requiresMediaMount;
  requiresMediaMount = {
    RequiresMountsFor = mediaPath;
  };
  servarrUMask = lib.mkForce "0002";
in
{
  host.observability.lanWan = {
    enable = true;
    interface = "ens18";
  };

  imports = [
    inputs.nixarr.nixosModules.default
    ./backup.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-srvarrvm.yaml;

  # NFS mounts with media
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems."${mediaPath}" = media;
  virtualisation.vmVariant.virtualisation.fileSystems."${mediaPath}" = media;

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
  systemd.services.audiobookshelf.unitConfig = requiresMediaMount;
  systemd.services.jellyseerr.unitConfig = requiresMediaMount;
  systemd.services.lidarr.unitConfig = requiresMediaMount;
  systemd.services.readarr.unitConfig = requiresMediaMount;
  systemd.services.readarr-audiobook.unitConfig = requiresMediaMount;
  systemd.services.transmission.unitConfig = wgUnitDepsWithMount;
  systemd.services.sabnzbd.unitConfig = wgUnitDepsWithMount;

  # Keep download dir locally to ease load on network and storage
  services.sabnzbd.allowConfigWrite = true;

  nixarr = {
    enable = true;
    vpn = {
      enable = true;
      wgConf = "/data/.secret/vpn/wg.conf";
      accessibleFrom = [
        "192.168.0.0/16"
      ];
    };

    jellyseerr.enable = true;
    prowlarr.enable = true;
    radarr.enable = true;
    lidarr.enable = true;
    readarr.enable = true;
    readarr-audiobook.enable = true;
    sonarr.enable = true;
    bazarr.enable = true;
    audiobookshelf.enable = true;

    # usenet
    sabnzbd = {
      enable = true;
      vpn.enable = true;
    };

    # torrent
    transmission = {
      enable = true;
      vpn.enable = true;
      peerPort = 45486;
      extraSettings = {
        compact-view = true;
        download-queue-enabled = true;
        download-queue-size = 100;
        rpc-bind-address = wgNamespaceAddress;
        rpc-host-whitelist = "${hostname},${config.services.avahi.hostName}.local";
        sort-mode = "progress";
      };
    };

  };

  systemd.services.sabnzbd.serviceConfig.ExecStartPre =
    let
      fix-incomplete-dir = pkgs.writeShellApplication {
        name = "fix-incomplete-dir";
        text = ''
          sed -i 's|download_dir = .*|download_dir = /data/.cache/usenet/incomplete|g' /var/lib/sabnzbd/sabnzbd.ini
        '';
      };
      sabnzbdSetHost = pkgs.writeShellApplication {
        name = "sabnzbd-set-host";
        runtimeInputs = [
          (pkgs.python3.withPackages (ps: [ ps.configobj ]))
        ];
        text = ''
          cfg_file="${config.nixarr.sabnzbd.stateDir}/sabnzbd.ini"
          if [ ! -f "$cfg_file" ]; then
            exit 0
          fi
          python3 - <<'PY'
          from pathlib import Path
          from configobj import ConfigObj

          cfg_path = Path("${config.nixarr.sabnzbd.stateDir}/sabnzbd.ini")
          cfg = ConfigObj(str(cfg_path))
          cfg.setdefault("misc", {})
          cfg["misc"]["host"] = "${wgNamespaceAddress}"
          cfg.write()
          PY
        '';
      };
    in
    [
      (lib.getExe' fix-incomplete-dir "fix-incomplete-dir")
      (lib.getExe sabnzbdSetHost)
    ];

  # nixarr hardcodes sabnzbd nginx proxy to 192.168.15.1; override to wg subnet.
  services.nginx.virtualHosts."127.0.0.1:${toString config.nixarr.sabnzbd.guiPort}".locations."/" = {
    proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString config.nixarr.sabnzbd.guiPort}";
  };

  # nixarr hardcodes transmission nginx proxy to 192.168.15.1; override to wg subnet.
  services.nginx.virtualHosts."127.0.0.1:${toString config.nixarr.transmission.uiPort}".locations."/" =
    {
      proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString config.nixarr.transmission.uiPort}";
    };

  # Move VPN bridge off the lab subnet to avoid routing conflicts.
  vpnNamespaces.wg = {
    bridgeAddress = wgBridgeAddress;
    namespaceAddress = wgNamespaceAddress;
  };

  # Apply upload shaping on the outer interface for WireGuard transport traffic.
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
          ];
          text = ''
            set -euo pipefail

            iface="$(${pkgs.iproute2}/bin/ip -o route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
            if [ -z "$iface" ]; then
              echo "failed to determine default egress interface" >&2
              exit 1
            fi

            case "''${1:-start}" in
              start)
                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root 2>/dev/null || true
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" root handle 1: htb default 20 r2q 1000
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1: classid 1:1 htb rate ${wgOuterLinkRate} ceil ${wgOuterLinkRate}
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:10 htb rate ${wgUploadRate} ceil ${wgUploadRate}
                ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:20 htb rate ${wgOuterLinkRate} ceil ${wgOuterLinkRate}
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:10 handle 10: cake bandwidth ${wgUploadRate} besteffort wash
                ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:20 handle 20: fq_codel
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" protocol ip parent 1: prio 10 flower ip_proto udp dst_port ${toString wgEndpointPort} classid 1:10
                ${pkgs.iproute2}/bin/tc filter add dev "$iface" protocol ipv6 parent 1: prio 11 flower ip_proto udp dst_port ${toString wgEndpointPort} classid 1:10
                ;;
              stop)
                ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root || true
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

  systemd.services."update-dynamic-ip" = {
    unitConfig = wgUnitDepsBase;
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart =
        let
          cookiePath = "/data/.secret/mam.cookies";
        in
        "${pkgs.curl}/bin/curl -c ${cookiePath} -b ${cookiePath} https://t.myanonamouse.net/json/dynamicSeedbox.php";
    };
    vpnconfinement = {
      enable = true;
      vpnnamespace = "wg";
    };
  };

  # expose to lan
  systemd.services.audiobookshelf.serviceConfig.ExecStart =
    lib.mkForce "${config.nixarr.audiobookshelf.package}/bin/audiobookshelf --host 0.0.0.0 --port ${toString config.nixarr.audiobookshelf.port}";
  networking.firewall.allowedTCPPorts = [ config.nixarr.audiobookshelf.port ];

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
                  }) arrServices;
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
