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
    vpn.enable = true;
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
}
