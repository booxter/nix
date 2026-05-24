{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  wgNamespaceAddress = hostInventory.nixosHostSpecsByName.srvarr.wgNamespace.namespaceAddress;
in
{
  # Keep download dir locally to ease load on network and storage
  services.sabnzbd.allowConfigWrite = true;

  nixarr.sabnzbd = {
    enable = true;
    vpn = {
      enable = true;
      configureNginx = false;
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

  host.vpnNamespaceBridgeAccess.tcpPorts = [ config.nixarr.sabnzbd.guiPort ];

  # nixarr hardcodes sabnzbd nginx proxy to 192.168.15.1; keep the host-local
  # helper on loopback, but target the actual namespace address directly.
  services.nginx.virtualHosts."127.0.0.1:${toString config.nixarr.sabnzbd.guiPort}" = {
    listen = lib.mkForce [
      {
        addr = "127.0.0.1";
        port = config.nixarr.sabnzbd.guiPort;
      }
    ];
    locations."/" = {
      recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString config.nixarr.sabnzbd.guiPort}";
    };
  };

  host.internalHttps.services.sabnzbd = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.nixarr.sabnzbd.guiPort}";
  };
}
