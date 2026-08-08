{
  config,
  hostInventory,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix;
  mediaPaths = config.host.srvarrPaths.sabnzbd;
  port = 6336;
  user = "sabnzbd";
  wgNamespaceAddress = hostInventory.nixosHosts.srvarr.wgNamespace.namespaceAddress;
  sabnzbdServerNames = [
    "news.frugalusenet.com"
    "news.newshosting.com"
    "eunews.frugalusenet.com"
    "bonus.frugalusenet.com"
    "usnews.blocknews.net"
    "reader.easyusenet.nl"
  ];
  mkSabnzbdServerSecretName = server: field: "sabnzbd/servers/${server}/${field}";
  sabnzbdSecretNames = [
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
  sabnzbdServerSecretIni = lib.concatMapStringsSep "\n\n" (server: ''
    [[${server}]]
    username = ${builtins.getAttr (mkSabnzbdServerSecretName server "username") config.sops.placeholder}
    password = ${builtins.getAttr (mkSabnzbdServerSecretName server "password") config.sops.placeholder}
  '') sabnzbdServerNames;
  mkUsenetDirRule = mode: path: "d '${path}' ${mode} ${user} media - -";
  usenetDirRules = [
    {
      mode = "0755";
      path = mediaPaths.root;
    }
    {
      mode = "0755";
      path = mediaPaths.incomplete;
    }
    {
      mode = "0775";
      path = mediaPaths.watch;
    }
    {
      mode = "0775";
      path = mediaPaths.complete;
    }
    {
      mode = "0775";
      path = mediaPaths.categories.lidarr;
    }
    {
      mode = "0775";
      path = mediaPaths.categories.radarr;
    }
    {
      mode = "0775";
      path = mediaPaths.categories.sonarr;
    }
    {
      mode = "0775";
      path = mediaPaths.categories.shelfmark;
    }
  ];
in
{
  imports = [
    ./sabnzbd-exporter.nix
  ];

  sops.secrets = lib.genAttrs sabnzbdSecretNames (_: { });

  sops.templates."sabnzbd-secret.ini" = {
    owner = user;
    group = "media";
    mode = "0400";
    content = ''
      [misc]
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
    group = "media";
    secretFiles = [ config.sops.templates."sabnzbd-secret.ini".path ];
    settings = import ./sabnzbd-settings.nix {
      language = hostInventory.regional.language.code;
      hostWhitelist = [
        config.networking.hostName
      ]
      ++ hostInventory.toInternalHttpsServiceHosts "sabnzbd";
      inherit wgNamespaceAddress;
      paths = mediaPaths;
      port = port;
    };
    user = user;
  };

  systemd.tmpfiles.rules = map (dir: mkUsenetDirRule dir.mode dir.path) usenetDirRules;

  systemd.services.sabnzbd = {
    serviceConfig = {
      Restart = "on-failure";
    };
    vpnConfinement = {
      enable = true;
      vpnNamespace = "wg";
    };
  };

  users.users.${user} = {
    uid = accounts.uids.sabnzbd;
  };

  host.vpnNamespaceBridgeAccess.tcpPorts = [ port ];

  services.nginx.virtualHosts."127.0.0.1:${toString port}" = {
    listen = lib.mkForce [
      {
        addr = "127.0.0.1";
        port = port;
      }
    ];
    locations."/" = {
      recommendedProxySettings = true;
      proxyWebsockets = true;
      proxyPass = lib.mkForce "http://${wgNamespaceAddress}:${toString port}";
    };
  };

  host.internalHttps.services.sabnzbd = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
  };
}
