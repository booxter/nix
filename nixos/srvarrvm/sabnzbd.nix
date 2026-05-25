{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.sabnzbd;
  mediaDir = config.host.srvarr.mediaDir;
  wgNamespaceAddress = hostInventory.nixosHostSpecsByName.srvarr.wgNamespace.namespaceAddress;
  concatStringsCommaIfExists =
    stringList:
    lib.optionalString (builtins.length stringList > 0) (
      lib.concatStringsSep "," stringList
    );
  userConfigs = {
    misc = {
      host = "192.168.15.1";
      port = cfg.port;
      download_dir = "${mediaDir}/usenet/.incomplete";
      complete_dir = "${mediaDir}/usenet/manual";
      dirscan_dir = "${mediaDir}/usenet/watch";
      host_whitelist = concatStringsCommaIfExists [ config.networking.hostName ];
      local_ranges = concatStringsCommaIfExists [ ];
      permissions = "775";
    };
  };
  iniBaseConfigFile = pkgs.writeTextFile {
    name = "base-config.ini";
    text = lib.generators.toINI { } userConfigs;
  };
  fixConfigPermissions = pkgs.writeShellApplication {
    name = "sabnzbd-fix-config-permissions";
    runtimeInputs = with pkgs; [ util-linux ];
    text = ''
      if [ ! -f ${cfg.stateDir}/sabnzbd.ini ]; then
        echo 'FAILURE: cannot change permissions of ${cfg.stateDir}/sabnzbd.ini, file does not exist'
        exit 1
      fi

      chmod 600 ${cfg.stateDir}/sabnzbd.ini
      chown ${cfg.user}:${cfg.group} ${cfg.stateDir}/sabnzbd.ini
    '';
  };
  userConfigsToPythonList =
    lib.attrsets.collect (f: !builtins.isAttrs f) (
      lib.attrsets.mapAttrsRecursive (
        path: value:
        "sab_config_map['"
        + (lib.concatStringsSep "']['" path)
        + "'] = '"
        + (builtins.toString value)
        + "'"
      ) userConfigs
    );
  applyUserConfigs = pkgs.writers.writePython3Bin "sabnzbd-set-user-values" {
    libraries = [ pkgs.python3Packages.configobj ];
  } ''
    # flake8: noqa
    from pathlib import Path
    from configobj import ConfigObj

    sab_config_path = Path("${cfg.stateDir}/sabnzbd.ini")
    if not sab_config_path.is_file() or sab_config_path.suffix != ".ini":
        raise Exception(f"{sab_config_path} is not a valid config file path.")

    sab_config_map = ConfigObj(str(sab_config_path))

    ${lib.concatStringsSep "\n" userConfigsToPythonList}

    sab_config_map.write()
  '';
  fixIncompleteDir = pkgs.writeShellApplication {
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
      cfg_file="${cfg.stateDir}/sabnzbd.ini"
      if [ ! -f "$cfg_file" ]; then
        exit 0
      fi
      python3 - <<'PY'
      from pathlib import Path
      from configobj import ConfigObj

      cfg_path = Path("${cfg.stateDir}/sabnzbd.ini")
      cfg = ConfigObj(str(cfg_path))
      cfg.setdefault("misc", {})
      cfg["misc"]["host"] = "${wgNamespaceAddress}"
      cfg.write()
      PY
    '';
  };
in
{
  # Keep download dir locally to ease load on network and storage.
  services.sabnzbd = {
    allowConfigWrite = true;
    configFile = "${cfg.stateDir}/sabnzbd.ini";
    enable = true;
    group = cfg.group;
    openFirewall = false;
    user = cfg.user;
  };

  systemd.tmpfiles.rules = [
    "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
    "C ${cfg.stateDir}/sabnzbd.ini - - - - ${iniBaseConfigFile}"
    "d '${mediaDir}/usenet'             0755 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/.incomplete' 0755 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/.watch'      0755 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/manual'      0775 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/lidarr'      0775 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/radarr'      0775 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/sonarr'      0775 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/shelfmark'   0775 ${cfg.user} ${cfg.group} - -"
  ];

  systemd.services.sabnzbd = {
    serviceConfig = {
      ExecStartPre = [
        ("+" + lib.getExe' fixConfigPermissions "sabnzbd-fix-config-permissions")
        (lib.getExe applyUserConfigs)
        (lib.getExe' fixIncompleteDir "fix-incomplete-dir")
        (lib.getExe sabnzbdSetHost)
      ];
      Restart = "on-failure";
      StartLimitBurst = 5;
    };
    vpnConfinement = {
      enable = true;
      vpnNamespace = "wg";
    };
  };

  users.users.${cfg.user} = {
    home = lib.mkForce "/var/empty";
    isSystemUser = true;
    uid = accounts.uids.sabnzbd;
  };

  host.vpnNamespaceBridgeAccess.tcpPorts = [ cfg.port ];

  # Keep the host-local helper on loopback, but target the actual namespace
  # address directly instead of the old fixed proxy address.
  services.nginx.virtualHosts."127.0.0.1:${toString cfg.port}" = {
    listen = lib.mkForce [
      {
        addr = "127.0.0.1";
        port = cfg.port;
      }
    ];
    locations."/" = {
      recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString cfg.port}";
    };
  };

  host.internalHttps.services.sabnzbd = {
    enable = true;
    upstream = "http://127.0.0.1:${toString cfg.port}";
  };
}
