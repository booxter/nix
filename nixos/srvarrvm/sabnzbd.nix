{
  config,
  hostInventory,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  cfg = config.host.srvarr.services.sabnzbd;
  mediaDir = config.host.srvarrPaths.mediaDir;
  wgNamespaceAddress = hostInventory.nixosHostSpecsByName.srvarr.wgNamespace.namespaceAddress;
  sabnzbdServerNames = [
    "news.frugalusenet.com"
    "news.newshosting.com"
    "eunews.frugalusenet.com"
    "bonus.frugalusenet.com"
    "usnews.blocknews.net"
    "reader.easyusenet.nl"
  ];
  mkSabnzbdServerSecretName = server: field: "sabnzbd/servers/${server}/${field}";
  sabnzbdSecretNames =
    [
      "sabnzbd/webUsername"
      "sabnzbd/webPassword"
      "sabnzbd/apiKey"
      "sabnzbd/nzbKey"
    ]
    ++ lib.concatMap (
      server:
      map (field: mkSabnzbdServerSecretName server field) [
        "username"
        "password"
      ]
    ) sabnzbdServerNames;
  sabnzbdServerSecretIni = lib.concatMapStringsSep "\n\n" (
    server: ''
      [[${server}]]
      username = ${builtins.getAttr (mkSabnzbdServerSecretName server "username") config.sops.placeholder}
      password = ${builtins.getAttr (mkSabnzbdServerSecretName server "password") config.sops.placeholder}
    ''
  ) sabnzbdServerNames;
  mkUsenetDirRule = mode: suffix: "d '${mediaDir}/usenet${suffix}' ${mode} ${cfg.user} ${cfg.group} - -";
  usenetDirRules = [
    {
      mode = "0755";
      suffix = "";
    }
    {
      mode = "0755";
      suffix = "/.incomplete";
    }
    {
      mode = "0775";
      suffix = "/watch";
    }
    {
      mode = "0775";
      suffix = "/manual";
    }
    {
      mode = "0775";
      suffix = "/lidarr";
    }
    {
      mode = "0775";
      suffix = "/radarr";
    }
    {
      mode = "0775";
      suffix = "/sonarr";
    }
    {
      mode = "0775";
      suffix = "/shelfmark";
    }
  ];
in
{
  imports = [
    ./sabnzbd-exporter.nix
  ];

  sops.secrets = lib.genAttrs sabnzbdSecretNames (_: { });

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
      ${sabnzbdServerSecretIni}
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

  systemd.tmpfiles.rules = map (dir: mkUsenetDirRule dir.mode dir.suffix) usenetDirRules;

  systemd.services.sabnzbd = {
    serviceConfig = {
      Restart = "on-failure";
    };
    vpnConfinement = {
      enable = true;
      vpnNamespace = "wg";
    };
  };

  users.users.${cfg.user} = {
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
