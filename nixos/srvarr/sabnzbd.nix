{
  config,
  lib,
  ...
}:
let
  accounts = import ./accounts.nix { hostAccounts = config.host.accounts; };
  mediaDir = config.host.storage.claims.media.mountPoint;
  port = 6336;
  user = "sabnzbd";
  vpnNamespace = config.host.vpn.namespaces.wg;
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
  downloadModel = import ../_mixins/downloads/model.nix { inherit config lib; };
  sabnzbdRoutes = lib.filterAttrs (_: route: route.clientName == "sabnzbd") downloadModel.routes;
  routeCategories = lib.mapAttrs' (
    _: route:
    lib.nameValuePair route.category {
      name = route.category;
      order = 50;
      pp = "";
      script = "Default";
      dir = route.path;
      newzbin = "";
      priority = -100;
    }
  ) sabnzbdRoutes;
  sabnzbdSettings = import ./sabnzbd-settings.nix {
    hostWhitelist = [
      config.networking.hostName
      "sabnzbd.${config.host.network.lanDomain}"
      "sabnzbd"
      "sabnzbd.local"
    ];
    inherit mediaDir;
    port = port;
    vpnNamespaceAddress = vpnNamespace.namespaceAddress;
  };
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
    settings = sabnzbdSettings // {
      categories = sabnzbdSettings.categories // routeCategories;
    };
    user = user;
  };

  host.storage.claims.media.directories =
    builtins.listToAttrs (
      map
        (path: {
          name = "usenet/${path}";
          value = {
            owner = user;
            mode = "0775";
          };
        })
        [
          "lidarr"
          "manual"
          "radarr"
          "sonarr"
          "watch"
        ]
    )
    // {
      usenet = {
        owner = user;
        mode = "0755";
      };
      "usenet/.incomplete" = {
        owner = user;
        mode = "0755";
      };
    };
  host.storage.claims.media.attachments.sabnzbd.unit = "sabnzbd";

  host.downloads.clients.sabnzbd = {
    kind = "usenet";
    implementation = "sabnzbd";
    endpoint = "http://127.0.0.1:${toString port}";
    authentication = {
      type = "api-key";
      secret = "sabnzbd/apiKey";
    };
    storageDefaults = {
      owner = user;
      group = "media";
      mode = "0775";
    };
  };

  systemd.services.sabnzbd = {
    serviceConfig = {
      Restart = "on-failure";
    };
  };

  users.users.${user} = {
    uid = accounts.uids.sabnzbd;
  };

  host.vpn.clients.sabnzbd = {
    namespace = "wg";
    bridgeTcpPorts = [ port ];
  };

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
      proxyPass = lib.mkForce "http://${vpnNamespace.namespaceAddress}:${toString port}";
    };
  };

  host.web.services.sabnzbd = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
    health = {
      frontend = {
        enable = true;
        path = "/oauth2/sign_in";
      };
      backend = {
        enable = true;
        path = "/__probe/sabnzbd-version";
      };
    };
    displayName = "SABNZB";
    dashboard = {
      enable = true;
      icon = "https://raw.githubusercontent.com/sabnzbd/sabnzbd/70d5134d28a0c1cddff49c97fa013cb67c356f9e/icons/logo-arrow.svg";
      section = "media-admin";
    };
  };
}
