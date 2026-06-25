{
  lib,
  username ? "ihrachyshka",
}:
let
  prxStateVersion = "25.11";
  prxNetIface = "enp5s0f0np0";
  lanDnsRecordTtlSeconds = 300;

  frame = "frame";
  nvws = "nvws";

  builderDhcpReservations = {
    "1" = {
      match = "bc:24:11:49:bf:fc";
      hostname = "prox-builder1vm";
      ip = "192.168.12.106";
    };
    "2" = {
      match = "bc:24:11:dc:ea:2c";
      hostname = "prox-builder2vm";
      ip = "192.168.13.243";
    };
    "3" = {
      match = "bc:24:11:2a:ee:d7";
      hostname = "prox-builder3vm";
      ip = "192.168.11.114";
    };
  };

  builderSpec =
    idx:
    let
      idx' = toString idx;
    in
    {
      isVM = true;
      name = "builder${idx'}";
      proxNode = "prx${idx'}-lab";
      dhcpReservation = builderDhcpReservations.${idx'};
      stateVersion = "25.11";
      memorySize = 64;
      balloonSize = 48;
      diskSize = 150;
      cores = 24;
      hmFull = false;
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

  mkService =
    {
      id,
      scope,
      owner,
      probePath,
      publicHost ? null,
      title ? lib.strings.toSentenceCase id,
      icon ? "sh:${id}",
      blackboxProbe ? true,
      showInGlance ? true,
    }:
    {
      inherit
        blackboxProbe
        icon
        id
        owner
        probePath
        scope
        showInGlance
        title
        ;
    }
    // lib.optionalAttrs (publicHost != null) { inherit publicHost; };

  mkDnsARecord = domain: ipv4Address: {
    type = "A_RECORD";
    ttlSeconds = lanDnsRecordTtlSeconds;
    inherit domain ipv4Address;
  };
  nixCacheUrlWithPriority = url: priority: "${url}?priority=${toString priority}";

  aliasIpv4Address =
    spec:
    if spec ? dhcpReservation then
      spec.dhcpReservation.ip
    else if spec ? lanAddress then
      spec.lanAddress
    else if spec ? ipAddress then
      spec.ipAddress
    else
      throw "host ${spec.name} does not have a stable IPv4 address for A-record aliases";
in
rec {
  virtPlatform = "aarch64-darwin";

  toProxVmName = name: "prox-${name}vm";
  isNixosVM = spec: spec.isVM or false;
  isNixosBM = spec: !(isNixosVM spec);
  hasStableIpv4Address = spec: spec ? dhcpReservation || spec ? lanAddress || spec ? ipAddress;
  toNixosConfigName = spec: spec.name;
  toNixosStableHostName = spec: spec.name;
  toNixosRuntimeHostName =
    spec:
    spec.hostname
      or (spec.dhcpReservation.hostname or (if isNixosVM spec then toProxVmName spec.name else spec.name)
      );
  toNixosPrimaryDnsName = spec: spec.dnsName or (toNixosRuntimeHostName spec);
  toNixosLegacyDnsNames =
    spec:
    lib.unique (
      (spec.legacyDnsNames or [ ])
      ++ lib.optionals (isNixosVM spec && toNixosPrimaryDnsName spec != toProxVmName spec.name) [
        (toProxVmName spec.name)
      ]
    );
  toNixosAllDnsNames =
    spec: lib.unique ([ (toNixosPrimaryDnsName spec) ] ++ toNixosLegacyDnsNames spec);
  toNixosShortDnsName = toNixosStableHostName;
  toLocalDnsName = label: "${label}.local";
  toInternalHttpsServiceHosts =
    serviceName:
    lib.unique [
      "${serviceName}.${site.lan.domain}"
      serviceName
      (toLocalDnsName serviceName)
    ];
  toNixosMigrationDnsNames =
    spec: lib.unique ([ (toNixosShortDnsName spec) ] ++ toNixosAllDnsNames spec);
  toNixosHostCertificateDnsNames =
    spec:
    let
      names = toNixosMigrationDnsNames spec;
    in
    lib.unique (
      names
      ++ map (name: "${name}.${site.lan.domain}") names
      ++ [ (toLocalDnsName (toNixosShortDnsName spec)) ]
    );
  toNixosLanDnsAliasLabels =
    spec:
    lib.unique (
      lib.optionals (
        isNixosVM spec
        && hasStableIpv4Address spec
        && toNixosShortDnsName spec != toNixosPrimaryDnsName spec
      ) [ (toNixosShortDnsName spec) ]
      ++ (spec.localDnsAliases or [ ])
    );
  toNixosSshHostName = toNixosPrimaryDnsName;
  toHostIpv4Address = aliasIpv4Address;
  toNixosHostIpv4Address = name: toHostIpv4Address nixosHostSpecsByName.${name};
  toUpsName = name: "${lib.strings.toUpper name}-UPS";
  srvarrAdminAppIds = [
    "bazarr"
    "lidarr"
    "prowlarr"
    "radarr"
    "sabnzbd"
    "sonarr"
  ];
  resolveService =
    service:
    service
    // lib.optionalAttrs (service ? publicHost) (rec {
      inherit (service) publicHost;
      url = "https://${publicHost}";
      probeUrl = "${url}${service.probePath}";
    })
    // lib.optionalAttrs (service.scope == "internal") {
      displayHost = toLocalDnsName (nixosHostSpecsByName.${service.owner}.name);
      probeHost =
        let
          spec = nixosHostSpecsByName.${service.owner};
        in
        toNixosShortDnsName spec;
    };

  site = rec {
    gids = {
      media = 169;
    };

    ports = {
      nfs = 2049;
    };

    nixCaches =
      let
        homeUrl = "https://nix-cache.${lan.domain}/default";
        flakehubUrl = "https://cache.flakehub.com";
      in
      {
        nixos = {
          url = "https://cache.nixos.org/";
          key = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
        };
        home = {
          url = homeUrl;
          key = "default:+epFjzN1YKGqqeraQczdEfRyIuzgWd6/nrifa0467QQ=";
          defaultUrl = nixCacheUrlWithPriority homeUrl 30;
          lanUrl = nixCacheUrlWithPriority homeUrl 10;
          vpnUrl = nixCacheUrlWithPriority homeUrl 30;
        };
        flakehub = {
          url = flakehubUrl;
          lanUrl = nixCacheUrlWithPriority flakehubUrl 30;
          vpnUrl = nixCacheUrlWithPriority flakehubUrl 10;
        };
      };

    lan = {
      cidr = "192.168.0.0/16";
      domain = "home.arpa";
      gateway = {
        host = "gateway";
        address = "192.168.0.1";
      };
      dhcpRanges = {
        main = {
          ranges = [
            {
              # Keep the pool below 192.168.15.0/24 because that block is
              # reserved for the lab/proxmox segment.
              start = "192.168.10.1";
              end = "192.168.14.255";
            }
          ];
        };
      };
      netboot = {
        host = "prx1-lab";
        bootfile = "netboot.xyz.efi";
      };
      staticRoutes = [
        {
          name = "wg-home";
          destination = wireguard.home.cidr;
          nextHop = toNixosHostIpv4Address wireguard.home.gateway.host;
          distance = 1;
        }
      ];
      customDhcpOptions = {
        domainSearch = {
          code = 119;
          name = "DomainSearch";
          type = "text";
          signed = false;
          encoding = "text";
        };
        classlessStaticRoutes = {
          code = 121;
          name = "ClasslessStaticRoutes";
          type = "text";
          signed = false;
          encoding = "text";
        };
      };

      dnsRecords =
        let
          lanDomain = lan.domain;
          staticDnsRecords = [
            (mkDnsARecord "unifi.${lanDomain}" lan.gateway.address)
          ];
          renderHostDnsRecords =
            spec:
            (map (domain: mkDnsARecord domain (aliasIpv4Address spec)) (spec.dnsAliases or [ ]))
            ++ map (label: mkDnsARecord "${label}.${lanDomain}" (aliasIpv4Address spec)) (
              toNixosLanDnsAliasLabels spec
            );
        in
        staticDnsRecords ++ builtins.concatMap renderHostDnsRecords nixosHostSpecs;
    };

    wireguard.home = {
      cidr = "10.83.0.0/24";
      gateway = {
        host = "gw";
        address = "10.83.0.1/24";
        listenPort = 51820;
        publicEndpoint = "wg.ihar.dev";
      };
      peers = {
        mair = {
          host = "mair";
          address = "10.83.0.10/32";
          publicKey = "j3TbXthVhDk2TVAag6Cr0MRLiCTaOPfBL8UeecG9Sx4=";
        };
        unifi-travel-router = {
          address = "10.83.0.20/32";
          publicKey = "B+s4ysMFr3GrIdXdKP4SxXM3JZ9ziCUVJXkLwEvPX1E=";
        };
      };
    };
  };

  sshTicket = {
    userCaPublicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJs0Zx3pG8L1SaGQSyD9Jqljt15KD7txMUrgu9lP85qRY89wjF7if3QQnp22jTBjgfuWrUW2GdFWwAbGmzvWDg8= ca-key-nix-infra@secretive.mair.local";
  };

  sso = {
    groups = {
      "sso-admins" = {
        title = "SSO administrators";
      };
      "infra-admins" = {
        title = "Infrastructure administrators";
      };
      "grafana-admins" = {
        title = "Grafana administrators";
      };
      "grafana-viewers" = {
        title = "Grafana viewers";
      };
      "paperless-admins" = {
        title = "Paperless administrators";
      };
      "paperless-users" = {
        title = "Paperless users";
      };
      "vikunja-users" = {
        title = "Vikunja users";
      };
      "ai-users" = {
        title = "Open WebUI users";
      };
      "romm-admins" = {
        title = "RomM administrators";
      };
      "romm-editors" = {
        title = "RomM editors";
      };
      "romm-viewers" = {
        title = "RomM viewers";
      };
      "media-admins" = {
        title = "Media administrators";
      };
      "media-users" = {
        title = "Media users";
      };
    };

    users = {
      ihar = {
        displayName = "ihar";
        mailAddresses = [ "ihar.hrachyshka@gmail.com" ];
        groups = [
          "sso-admins"
          "infra-admins"
          "grafana-admins"
          "paperless-admins"
          "paperless-users"
          "vikunja-users"
          "ai-users"
          "romm-admins"
          "media-admins"
          "media-users"
        ];
      };
      kasia = {
        displayName = "kasia";
        mailAddresses = [ "kasia.bondarava@gmail.com" ];
        groups = [
          "paperless-users"
          "vikunja-users"
          "ai-users"
          "media-users"
        ];
      };
    };
  };

  services = [
    (resolveService (mkService {
      id = "id";
      title = "SSO";
      icon = "sh:kanidm";
      scope = "external";
      owner = "pki";
      publicHost = "id.ihar.dev";
      probePath = "/status";
      showInGlance = false;
    }))
    (resolveService (mkService {
      id = "jellyfin";
      scope = "external";
      owner = "beast";
      publicHost = "jf.ihar.dev";
      probePath = "/web/";
    }))
    (resolveService (mkService {
      id = "seerr";
      scope = "external";
      owner = "srvarr";
      publicHost = "js.ihar.dev";
      probePath = "/login";
    }))
    (resolveService (mkService {
      id = "romm";
      title = "RomM";
      scope = "external";
      owner = "srvarr";
      publicHost = "game.ihar.dev";
      probePath = "/api/heartbeat";
    }))
    (resolveService (mkService {
      id = "grafana";
      scope = "internal";
      owner = "fana";
      probePath = "/login";
    }))
    (resolveService (mkService {
      id = "radarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
    }))
    (resolveService (mkService {
      id = "sonarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
    }))
    (resolveService (mkService {
      id = "lidarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
    }))
    (resolveService (mkService {
      id = "letterboxd-list-radarr";
      title = "Letterboxd Radarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/";
      showInGlance = false;
    }))
    (resolveService (mkService {
      id = "aurral";
      scope = "external";
      owner = "srvarr";
      publicHost = "mu.ihar.dev";
      probePath = "/oauth2/sign_in";
    }))
    (resolveService (mkService {
      id = "audiobookshelf";
      scope = "external";
      owner = "srvarr";
      publicHost = "au.ihar.dev";
      probePath = "";
    }))
    (resolveService (mkService {
      id = "shelfmark";
      scope = "external";
      owner = "srvarr";
      publicHost = "shelf.ihar.dev";
      probePath = "/";
    }))
    (resolveService (mkService {
      id = "vikunja";
      scope = "external";
      owner = "org";
      publicHost = "vi.ihar.dev";
      probePath = "";
    }))
    (resolveService (mkService {
      id = "paperless";
      title = "Paperless";
      icon = "sh:paperless-ngx";
      scope = "external";
      owner = "org";
      publicHost = "papers.ihar.dev";
      probePath = "/accounts/login/";
    }))
    (resolveService (mkService {
      id = "llm";
      title = "LLM Gateway";
      icon = "sh:litellm";
      scope = "external";
      owner = "org";
      publicHost = "llm.ihar.dev";
      probePath = "/health/liveliness";
    }))
    (resolveService (mkService {
      id = "ai";
      title = "Open WebUI";
      icon = "sh:open-webui";
      scope = "external";
      owner = "org";
      publicHost = "ai.ihar.dev";
      probePath = "/";
    }))
    (resolveService (mkService {
      id = "ollama";
      title = "Ollama";
      scope = "internal";
      owner = "frame";
      probePath = "/";
      blackboxProbe = false;
      showInGlance = false;
    }))
    (resolveService (mkService {
      id = "bazarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
    }))
    (resolveService (mkService {
      id = "prowlarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
    }))
    (resolveService (mkService {
      id = "transmission";
      scope = "internal";
      owner = "srvarr";
      probePath = "/transmission/web/";
    }))
    (resolveService (mkService {
      id = "sabnzbd";
      title = "SABNZB";
      icon = "https://raw.githubusercontent.com/sabnzbd/sabnzbd/70d5134d28a0c1cddff49c97fa013cb67c356f9e/icons/logo-arrow.svg";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
    }))
  ];

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

  darwinHosts = {
    mair = {
      stateVersion = 6;
      hmStateVersion = "25.11";
      hostname = "mair";
      platform = "aarch64-darwin";
      isDesktop = true;
      isLaptop = true;
      lanWanInterfaces = [ "en0" ];
    };
    mmini = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      hostname = "mmini";
      platform = "aarch64-darwin";
      isDesktop = true;
      upsHost = frame;
      lanWanInterfaces = [ "en0" ];
    };
    JGWXHWDL4X = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      hostname = "JGWXHWDL4X";
      platform = "aarch64-darwin";
      isDesktop = true;
      isWork = true;
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
      isDesktop = true;
      localDnsAliases = [ "ollama" ];
      dhcpReservation = {
        match = "9c:bf:0d:00:fa:0a";
        hostname = "frame";
        ip = "192.168.11.228";
      };
    }
    {
      hostKind = "proxmox";
      name = nvws;
      inherit username;
      isWork = true;
      stateVersion = "25.11";
      netIface = "enp3s0f0";
      ipAddress = "192.168.15.100";
      macAddress = "ac:b4:80:40:05:2e";
      dhcpReservation = {
        match = "ac:b4:80:40:05:2e";
        hostname = "nvws";
        ip = "192.168.15.100";
      };
    }
    {
      hostKind = "nixos";
      name = "beast";
      stateVersion = "25.11";
      platform = "x86_64-linux";
      critical = true;
      dnsAliases = map (service: service.publicHost) publicServices;
      hmFull = false;
      hardware.igpu.renderDevice = "/dev/dri/renderD128";
      dhcpReservation = {
        match = "bc:fc:e7:3b:fe:da";
        hostname = "beast";
        ip = "192.168.16.3";
      };
    }
    {
      hostKind = "proxmox";
      name = "prx1-lab";
      inherit username;
      stateVersion = prxStateVersion;
      netIface = prxNetIface;
      ipAddress = "192.168.15.10";
      macAddress = "38:05:25:30:7d:89";
      dhcpReservation = {
        match = "38:05:25:30:7d:89";
        hostname = "prx1-lab";
        ip = "192.168.15.10";
      };
    }
    {
      hostKind = "proxmox";
      name = "prx2-lab";
      inherit username;
      upsHost = "prx1-lab";
      stateVersion = prxStateVersion;
      netIface = prxNetIface;
      ipAddress = "192.168.15.11";
      macAddress = "38:05:25:30:7f:7d";
      dhcpReservation = {
        match = "38:05:25:30:7f:7d";
        hostname = "prx2-lab";
        ip = "192.168.15.11";
      };
    }
    {
      hostKind = "proxmox";
      name = "prx3-lab";
      inherit username;
      upsHost = "prx1-lab";
      stateVersion = prxStateVersion;
      netIface = prxNetIface;
      ipAddress = "192.168.15.12";
      macAddress = "38:05:25:30:7d:69";
      dhcpReservation = {
        match = "38:05:25:30:7d:69";
        hostname = "prx3-lab";
        ip = "192.168.15.12";
      };
    }
    {
      isVM = true;
      name = "nv";
      isWork = true;
      upsHost = nvws;
      cores = 64;
      memorySize = 128;
      sshPort = 10000;
      proxNode = "nvws";
    }
    {
      isVM = true;
      name = "cache";
      upsHost = "prx1-lab";
      localDnsAliases = [ "nix-cache" ];
      dhcpReservation = {
        match = "bc:24:11:0d:85:41";
        hostname = "prox-cachevm";
        ip = "192.168.20.7";
      };
      sshPort = 10004;
      hmFull = false;
      cores = 16;
      memorySize = 16;
      diskSize = 50; # actual cache is on NFS
    }
    {
      isVM = true;
      name = "srvarr";
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
      localDnsAliases = [
        "glance"
        "seerr"
        "radarr"
        "sonarr"
        "lidarr"
        "bazarr"
        "prowlarr"
        "letterboxd-list-radarr"
        "romm"
        "aurral"
        "audiobookshelf"
        "shelfmark"
        "sabnzbd"
        "tmission"
      ];
      wgNamespace = {
        bridgeAddress = "192.168.50.5";
        namespaceAddress = "192.168.50.1";
      };
      cores = 16;
      memorySize = 32;
      sshPort = 10005;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:19:4d:d1";
        hostname = "prox-srvarrvm";
        ip = "192.168.20.2";
      };
    }
    {
      isVM = true;
      name = "fana";
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
      localDnsAliases = [
        "grafana"
        "loki"
      ];
      cores = 8;
      memorySize = 16;
      diskSize = 300;
      sshPort = 10006;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:06:e8:8b";
        hostname = "prox-fanavm";
        ip = "192.168.13.110";
      };
    }
    {
      isVM = true;
      name = "gw";
      upsHost = "prx1-lab";
      cores = 2;
      memorySize = 8;
      diskSize = 64;
      sshPort = 10008;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:91:b5:77";
        hostname = "prox-gwvm";
        ip = "192.168.20.3";
      };
    }
    {
      isVM = true;
      name = "org";
      platform = "x86_64-linux";
      localDnsAliases = [
        "vikunja"
        "paperless"
        "llm"
        "ai"
      ];
      upsHost = "prx1-lab";
      cores = 4;
      memorySize = 8;
      diskSize = 80;
      sshPort = 10009;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:fd:eb:9c";
        hostname = "prox-orgvm";
        ip = "192.168.20.4";
      };
    }
    {
      isVM = true;
      name = "pki";
      platform = "x86_64-linux";
      localDnsAliases = [ "id" ];
      caServer = {
        port = 8443;
        # Fixed step-ca HTTP API route for the trusted root bundle.
        rootsPath = "/roots.pem";
      };
      upsHost = "prx1-lab";
      cores = 2;
      memorySize = 4;
      diskSize = 40;
      sshPort = 10010;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:c6:ab:fc";
        hostname = "prox-pkivm";
        ip = "192.168.20.5";
      };
    }
  ]
  ++ map (idx: (builderSpec idx) // { upsHost = "prx1-lab"; }) [
    1
    2
    3
  ];

  managedDhcpReservations = map (spec: spec.dhcpReservation) (
    builtins.filter (spec: spec ? dhcpReservation) nixosHostSpecs
  );

  dhcpReservationsByHostname = builtins.listToAttrs (
    map (reservation: {
      name = reservation.hostname;
      value = reservation;
    }) (managedDhcpReservations ++ staticDhcpReservations)
  );

  nixosHostSpecsByName = builtins.listToAttrs (
    map (spec: {
      name = spec.name;
      value = spec;
    }) nixosHostSpecs
  );

  publicServices = builtins.filter (service: service.scope == "external") services;

  glanceServices = builtins.filter (service: service.showInGlance) services;

  blackboxServices = builtins.filter (service: service.blackboxProbe) services;

  servicesById = builtins.listToAttrs (
    map (service: {
      name = service.id;
      value = service;
    }) services
  );
}
