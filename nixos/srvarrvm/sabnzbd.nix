{
  config,
  hostInventory,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.sabnzbd;
  mediaDir = config.host.srvarr.mediaDir;
  legacyStateDir = "${config.host.srvarr.stateDir}/sabnzbd";
  wgNamespaceAddress = hostInventory.nixosHostSpecsByName.srvarr.wgNamespace.namespaceAddress;
in
{
  sops.secrets = {
    "sabnzbd/webUsername" = { };
    "sabnzbd/webPassword" = { };
    "sabnzbd/apiKey" = { };
    "sabnzbd/nzbKey" = { };
    "sabnzbd/servers/news.frugalusenet.com/username" = { };
    "sabnzbd/servers/news.frugalusenet.com/password" = { };
    "sabnzbd/servers/news.newshosting.com/username" = { };
    "sabnzbd/servers/news.newshosting.com/password" = { };
    "sabnzbd/servers/eunews.frugalusenet.com/username" = { };
    "sabnzbd/servers/eunews.frugalusenet.com/password" = { };
    "sabnzbd/servers/bonus.frugalusenet.com/username" = { };
    "sabnzbd/servers/bonus.frugalusenet.com/password" = { };
    "sabnzbd/servers/usnews.blocknews.net/username" = { };
    "sabnzbd/servers/usnews.blocknews.net/password" = { };
    "sabnzbd/servers/reader.easyusenet.nl/username" = { };
    "sabnzbd/servers/reader.easyusenet.nl/password" = { };
  };

  sops.templates."sabnzbd-secret.ini" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      [misc]
      username = ${config.sops.placeholder."sabnzbd/webUsername"}
      password = ${config.sops.placeholder."sabnzbd/webPassword"}
      api_key = ${config.sops.placeholder."sabnzbd/apiKey"}
      nzb_key = ${config.sops.placeholder."sabnzbd/nzbKey"}

      [servers]
      [[news.frugalusenet.com]]
      username = ${config.sops.placeholder."sabnzbd/servers/news.frugalusenet.com/username"}
      password = ${config.sops.placeholder."sabnzbd/servers/news.frugalusenet.com/password"}

      [[news.newshosting.com]]
      username = ${config.sops.placeholder."sabnzbd/servers/news.newshosting.com/username"}
      password = ${config.sops.placeholder."sabnzbd/servers/news.newshosting.com/password"}

      [[eunews.frugalusenet.com]]
      username = ${config.sops.placeholder."sabnzbd/servers/eunews.frugalusenet.com/username"}
      password = ${config.sops.placeholder."sabnzbd/servers/eunews.frugalusenet.com/password"}

      [[bonus.frugalusenet.com]]
      username = ${config.sops.placeholder."sabnzbd/servers/bonus.frugalusenet.com/username"}
      password = ${config.sops.placeholder."sabnzbd/servers/bonus.frugalusenet.com/password"}

      [[usnews.blocknews.net]]
      username = ${config.sops.placeholder."sabnzbd/servers/usnews.blocknews.net/username"}
      password = ${config.sops.placeholder."sabnzbd/servers/usnews.blocknews.net/password"}

      [[reader.easyusenet.nl]]
      username = ${config.sops.placeholder."sabnzbd/servers/reader.easyusenet.nl/username"}
      password = ${config.sops.placeholder."sabnzbd/servers/reader.easyusenet.nl/password"}
    '';
  };

  services.sabnzbd = {
    enable = true;
    allowConfigWrite = false;
    configFile = null;
    group = cfg.group;
    secretFiles = [ config.sops.templates."sabnzbd-secret.ini".path ];
    settings = import ./sabnzbd-settings.nix {
      hostName = config.networking.hostName;
      inherit
        mediaDir
        wgNamespaceAddress
        ;
      port = cfg.port;
    };
    user = cfg.user;
  };

  system.activationScripts."migrate-sabnzbd-state".text = ''
    if [ -d ${legacyStateDir} ] && [ ! -e /var/lib/sabnzbd/.migrated-from-legacy ]; then
      install -d -m 0750 -o ${cfg.user} -g ${cfg.group} /var/lib/sabnzbd

      if [ -z "$(find /var/lib/sabnzbd -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        cp -a ${legacyStateDir}/. /var/lib/sabnzbd/
        chown -R ${cfg.user}:${cfg.group} /var/lib/sabnzbd
      fi

      touch /var/lib/sabnzbd/.migrated-from-legacy
      chown ${cfg.user}:${cfg.group} /var/lib/sabnzbd/.migrated-from-legacy
    fi
  '';

  systemd.tmpfiles.rules = [
    "d '${mediaDir}/usenet'             0755 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/.incomplete' 0755 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/watch'       0755 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/manual'      0775 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/lidarr'      0775 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/radarr'      0775 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/sonarr'      0775 ${cfg.user} ${cfg.group} - -"
    "d '${mediaDir}/usenet/shelfmark'   0775 ${cfg.user} ${cfg.group} - -"
  ];

  systemd.services.sabnzbd = {
    serviceConfig = {
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
