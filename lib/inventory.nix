{
  lib,
  username ? "ihrachyshka",
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  prxStateVersion = "25.11";
  prxNetIface = "enp5s0f0np0";
  lanDnsRecordTtlSeconds = 300;

  frame = "frame";
  mmini = "mmini";
  nvws = "nvws";
  glanceCategories = [
    {
      id = "user";
      title = "User Apps";
    }
    {
      id = "media-admin";
      title = "Media Admin";
    }
    {
      id = "infrastructure";
      title = "Infrastructure";
    }
  ];
  glanceCategoryIds = map (category: category.id) glanceCategories;

  builderDhcpReservations = {
    "1" = {
      match = "bc:24:11:49:bf:fc";
      hostname = "builder1";
      ip = "192.168.12.106";
    };
    "2" = {
      match = "bc:24:11:dc:ea:2c";
      hostname = "builder2";
      ip = "192.168.13.243";
    };
    "3" = {
      match = "bc:24:11:2a:ee:d7";
      hostname = "builder3";
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
      backendProbe ? null,
      showInGlance ? true,
      glanceCategory ? null,
    }:
    {
      inherit
        blackboxProbe
        glanceCategory
        icon
        id
        owner
        probePath
        scope
        showInGlance
        title
        ;
    }
    // lib.optionalAttrs (backendProbe != null) { inherit backendProbe; }
    // lib.optionalAttrs (publicHost != null) { inherit publicHost; };

  assertValidService =
    service:
    let
      category = service.glanceCategory or null;
      categoryLabel = if category == null then "<missing>" else category;
    in
    assert lib.asserts.assertMsg (
      !service.showInGlance || category != null
    ) "Glance service ${service.id} must set glanceCategory";
    assert lib.asserts.assertMsg (
      category == null || builtins.elem category glanceCategoryIds
    ) "Glance service ${service.id} uses unknown glanceCategory '${categoryLabel}'";
    service;

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
    else if spec ? ipAddress then
      spec.ipAddress
    else
      throw "host ${spec.name} does not have a stable IPv4 address";
in
rec {
  inherit glanceCategories;

  virtPlatform = "aarch64-darwin";

  isNixosVM = spec: spec.isVM or false;
  isNixosBM = spec: !(isNixosVM spec);
  toSecretDomain = spec: spec.secretDomain or (if spec.isWork or false then "work" else "main");
  toNixosConfigName = spec: spec.name;
  toNixosRuntimeHostName = spec: spec.hostname or (spec.dhcpReservation.hostname or spec.name);
  toNixosPrimaryDnsName = spec: spec.dnsName or (toNixosRuntimeHostName spec);
  toNixosShortDnsName = spec: spec.name;
  toLocalDnsName = label: "${label}.local";
  toInternalHttpsServiceHosts =
    serviceName:
    let
      mkHosts = label: [
        "${label}.${site.lan.domain}"
        label
        (toLocalDnsName label)
      ];
      serviceLabels = {
        transmission = [ "tmission" ];
      };
    in
    lib.unique (lib.concatMap mkHosts (serviceLabels.${serviceName} or [ serviceName ]));
  toNixosHostCertificateDnsNames =
    spec:
    let
      primaryName = toNixosPrimaryDnsName spec;
      shortName = toNixosShortDnsName spec;
    in
    lib.unique ([
      primaryName
      shortName
      "${primaryName}.${site.lan.domain}"
      "${shortName}.${site.lan.domain}"
      (toLocalDnsName shortName)
    ]);
  toNixosLanDnsAliasLabels = spec: lib.unique (spec.localDnsAliases or [ ]);
  toHostIpv4Address = aliasIpv4Address;
  toNixosHostIpv4Address = name: toHostIpv4Address nixosHostSpecsByName.${name};
  toUpsName = name: "${lib.strings.toUpper name}-UPS";
  srvarrAdminAppIds = [
    "bazarr"
    "houndarr"
    "lidarr"
    "prowlarr"
    "radarr"
    "sabnzbd"
    "sonarr"
    "transmission"
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
    public = {
      domain = "ihar.dev";
    };

    gids = {
      media = 169;
    };

    ports = {
      nfs = 2049;
      watchstate = 8080;
    };

    nixCaches =
      let
        homeUrl = "https://nix-cache.${lan.domain}/default";
        flakehubUrl = "https://cache.flakehub.com";
      in
      {
        nixos = {
          url = "https://cache.nixos.org/";
          key = readPublicKey ../public-keys/nix-cache/nixos.pub;
        };
        home = {
          url = homeUrl;
          key = readPublicKey ../public-keys/nix-cache/home.pub;
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
        publicEndpoint = "wg.${public.domain}";
      };
      peers = {
        mair = {
          host = "mair";
          address = "10.83.0.10/32";
          publicKey = readPublicKey ../public-keys/wireguard/home-mair.pub;
        };
        unifi-travel-router = {
          address = "10.83.0.20/32";
          publicKey = readPublicKey ../public-keys/wireguard/home-unifi-travel-router.pub;
        };
      };
    };
  };

  sshTicket =
    let
      secretivePublicKey = readPublicKey ../public-keys/ssh-ca/fleet-user-ca.pub;
      yubikeyPublicKey = readPublicKey ../public-keys/yubikey.pub;
      yubikeyIssuer = {
        publicKey = yubikeyPublicKey;
        keyName = "id_ed25519_sk_rk";
        useAgent = false;
      };
    in
    {
      trustedCaPublicKeys = [
        secretivePublicKey
        yubikeyPublicKey
      ];

      issuers = {
        mair = {
          publicKey = secretivePublicKey;
          keyName = "fleet-user-ca.pub";
          useAgent = true;
        };
        ${frame} = yubikeyIssuer;
        ${mmini} = yubikeyIssuer;
      };
    };

  # Public YubiKey allocation facts. Keep PINs, PUKs, management keys, and
  # private key material out of inventory.
  yubi = {
    devices.personal = {
      owner = username;
      hosts = [
        frame
        mmini
      ];

      applets = {
        fido2 = {
          residentSsh = {
            keyName = "id_ed25519_sk_rk";
            hosts = [
              frame
              mmini
            ];
            purposes = [
              "ssh-client-auth"
              "git-ssh-signing"
              "ssh-ticket-ca-signing"
            ];
          };

          pamU2f.${frame} = {
            host = frame;
            appId = "pam://${frame}";
            origin = "pam://${frame}";
          };
        };

        piv = {
          managementKey = {
            algorithm = "TDES";
            storage = "protected-by-pin";
          };

          occupiedSlots = {
            "9A" = {
              host = mmini;
              purpose = "macOS SmartCardServices login";
              subject = "CN=ihrachyshka@mmini PIV auth";
              certificateSha1 = "EE:44:3A:CB:F7:9B:70:13:C2:9A:D8:53:1C:47:25:F3:FF:4C:57:85";
              macosIdentityHash = "1CD7472BD8C5B0129801906597B581CC8FE05968";
              macosToken = "com.apple.pivtoken:9F19388BE1FB4DEF83A8F2AC72223BF6";
            };

            "9D" = {
              host = mmini;
              purpose = "PIV key management certificate";
              subject = "CN=ihrachyshka@mmini PIV key management";
              certificateSha1 = "8F:60:00:48:80:3B:94:E8:DB:6A:E9:28:41:8C:EF:8E:3A:3B:EF:C7";
            };
          };

          retiredSlots = {
            "1" = {
              hosts = [
                frame
                mmini
              ];
              purpose = "age-plugin-yubikey sops identity";
              name = "nix sops age";
              recipient = "age1yubikey1qgnnyzk9ftl6uetyk6r8kd8eqxe7emcsgedaq7jycjk6sxt483p55chyk9r";
              identityFileName = "yubi-nix.txt";
              pinPolicy = "once";
              touchPolicy = "cached";
            };
          };
        };
      };
    };
  };

  sso = {
    applications = {
      "home-assistant" = {
        adminGroup = "home-admins";
        userGroup = "home-users";
        bootstrapOwner = "ihar";
        bootstrapLanguage = "en";
      };
      pinepods = {
        adminGroup = "media-admins";
        userGroup = "media-users";
        bootstrapOwner = "ihar";
      };
      romm = {
        adminGroup = "romm-admins";
        editorGroup = "romm-editors";
        viewerGroup = "romm-viewers";
        bootstrapOwner = "ihar";
      };
      watchstate = {
        adminGroup = "media-admins";
        bootstrapOwner = "ihar";
      };
    };

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
      "home-admins" = {
        title = "Home Assistant administrators";
      };
      "home-users" = {
        title = "Home Assistant users";
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
      "oidc-probe-users" = {
        title = "OIDC synthetic probe users";
      };
      "search-probe-users" = {
        title = "Search synthetic probe users";
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
          "home-admins"
          "home-users"
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
          "romm-viewers"
          "home-users"
        ];
      };
      oidc-probe-user = {
        displayName = "OIDC synthetic probe";
        mailAddresses = [ "oidc-probe@${site.public.domain}" ];
        groups = [
          "oidc-probe-users"
          "search-probe-users"
        ];
      };
    };
  };

  services = map assertValidService [
    (resolveService (mkService {
      id = "id";
      title = "SSO";
      icon = "sh:kanidm";
      scope = "external";
      owner = "pki";
      publicHost = "id.${site.public.domain}";
      probePath = "/status";
      showInGlance = false;
    }))
    (resolveService (mkService {
      id = "dash";
      title = "Dashboard";
      icon = "sh:glance";
      scope = "external";
      owner = "srvarr";
      publicHost = "dash.${site.public.domain}";
      probePath = "/";
      showInGlance = false;
    }))
    (resolveService (mkService {
      id = "jellyfin";
      scope = "external";
      owner = "beast";
      publicHost = "jf.${site.public.domain}";
      probePath = "/web/";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "jfstat";
      title = "Jellystat";
      icon = "di:jellystat";
      scope = "internal";
      owner = "beast";
      probePath = "/auth/isConfigured";
      glanceCategory = "media-admin";
    }))
    (resolveService (mkService {
      id = "watchstate";
      title = "WatchState";
      scope = "internal";
      owner = "beast";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/v1/api/system/healthcheck";
      glanceCategory = "media-admin";
    }))
    (resolveService (mkService {
      id = "seerr";
      scope = "external";
      owner = "srvarr";
      publicHost = "js.${site.public.domain}";
      probePath = "/login";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "romm";
      title = "RomM";
      scope = "external";
      owner = "srvarr";
      publicHost = "game.${site.public.domain}";
      probePath = "/api/heartbeat";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "grafana";
      scope = "internal";
      owner = "fana";
      probePath = "/login";
      glanceCategory = "infrastructure";
    }))
    (resolveService (mkService {
      id = "home";
      title = "Home Assistant";
      icon = "sh:home-assistant";
      scope = "internal";
      owner = "home";
      probePath = "/";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "houndarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health";
      glanceCategory = "media-admin";
    }))
    (resolveService (mkService {
      id = "radarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }))
    (resolveService (mkService {
      id = "sonarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }))
    (resolveService (mkService {
      id = "lidarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
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
      publicHost = "mu.${site.public.domain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health/live";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "audiobookshelf";
      scope = "external";
      owner = "srvarr";
      publicHost = "au.${site.public.domain}";
      probePath = "";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "pinepods";
      title = "PinePods";
      icon = "https://raw.githubusercontent.com/madeofpendletonwool/PinePods/0.9.0/images/icon-192.png";
      scope = "external";
      owner = "srvarr";
      publicHost = "pod.${site.public.domain}";
      probePath = "/api/health";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "shelfmark";
      scope = "external";
      owner = "srvarr";
      publicHost = "shelf.${site.public.domain}";
      probePath = "/api/health";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "vikunja";
      scope = "external";
      owner = "org";
      publicHost = "vi.${site.public.domain}";
      probePath = "";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "paperless";
      title = "Paperless";
      icon = "sh:paperless-ngx";
      scope = "external";
      owner = "org";
      publicHost = "papers.${site.public.domain}";
      probePath = "/accounts/login/";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "paperless-gpt";
      title = "Paperless GPT";
      icon = "sh:paperless-ngx";
      scope = "internal";
      owner = "org";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/version";
      glanceCategory = "infrastructure";
    }))
    (resolveService (mkService {
      id = "llm";
      title = "LLM Gateway";
      icon = "sh:litellm";
      scope = "external";
      owner = "org";
      publicHost = "llm.${site.public.domain}";
      probePath = "/health/liveliness";
      glanceCategory = "infrastructure";
    }))
    (resolveService (mkService {
      id = "ai";
      title = "Open WebUI";
      icon = "sh:open-webui";
      scope = "external";
      owner = "org";
      publicHost = "ai.${site.public.domain}";
      probePath = "/";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "search";
      title = "Search";
      icon = "sh:searxng";
      scope = "external";
      owner = "org";
      publicHost = "search.${site.public.domain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/healthz";
      glanceCategory = "user";
    }))
    (resolveService (mkService {
      id = "tg";
      title = "Telegram Archive";
      icon = "sh:telegram";
      scope = "internal";
      owner = "org";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health";
      glanceCategory = "user";
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
      backendProbe.path = "/api/system/ping";
      glanceCategory = "media-admin";
    }))
    (resolveService (mkService {
      id = "prowlarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }))
    (resolveService (mkService {
      id = "transmission";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe = {
        path = "/__probe/transmission-rpc";
        blackboxModule = "http_service_409";
      };
      glanceCategory = "media-admin";
    }))
    (resolveService (mkService {
      id = "sabnzbd";
      title = "SABNZB";
      icon = "https://raw.githubusercontent.com/sabnzbd/sabnzbd/70d5134d28a0c1cddff49c97fa013cb67c356f9e/icons/logo-arrow.svg";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/__probe/sabnzbd-version";
      glanceCategory = "media-admin";
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
      hardware.gpuFamilies = [ "apple" ];
      lanWanInterfaces = [ "en0" ];
    };
    mmini = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      hostname = "mmini";
      platform = "aarch64-darwin";
      isDesktop = true;
      hardware.gpuFamilies = [ "apple" ];
      upsHost = frame;
      lanWanInterfaces = [ "en0" ];
    };
    JGWXHWDL4X = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      hostname = "JGWXHWDL4X";
      platform = "aarch64-darwin";
      isDesktop = true;
      isLaptop = true;
      isWork = true;
      hardware.gpuFamilies = [ "apple" ];
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
      sshTicket.allowX11Forwarding = true;
      localDnsAliases = [ "ollama" ];
      hardware.gpuFamilies = [ "amd" ];
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
      hardware.gpuFamilies = [ "nvidia" ];
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
      dnsAliases = builtins.filter (domain: domain != "dash.${site.public.domain}") (
        map (service: service.publicHost) publicServices
      );
      localDnsAliases = [
        "jfstat"
        "watchstate"
      ];
      hmFull = false;
      hardware.gpuFamilies = [ "intel" ];
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
      hardware.gpuFamilies = [ "intel" ];
      dnsAliases = [ "proxmox.${site.lan.domain}" ];
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
      hardware.gpuFamilies = [ "intel" ];
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
      hardware.gpuFamilies = [ "intel" ];
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
      dhcpReservation = {
        match = "bc:24:11:ed:30:d3";
        hostname = "nv";
        ip = "192.168.10.138";
      };
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
        hostname = "cache";
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
      dnsAliases = [ "dash.${site.public.domain}" ];
      localDnsAliases = [
        "dash"
        "glance"
        "seerr"
        "houndarr"
        "radarr"
        "sonarr"
        "lidarr"
        "bazarr"
        "prowlarr"
        "letterboxd-list-radarr"
        "romm"
        "aurral"
        "audiobookshelf"
        "pinepods"
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
        hostname = "srvarr";
        ip = "192.168.20.2";
      };
    }
    {
      isVM = true;
      name = "fana";
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
      localDnsAliases = [
        "alertmanager"
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
        hostname = "fana";
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
        hostname = "gw";
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
        "paperless-gpt"
        "llm"
        "ai"
        "search"
        "tg"
      ];
      upsHost = "prx1-lab";
      cores = 4;
      memorySize = 16;
      diskSize = 80;
      sshPort = 10009;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:fd:eb:9c";
        hostname = "org";
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
      diskSize = 50;
      sshPort = 10010;
      hmFull = false;
      dhcpReservation = {
        match = "bc:24:11:c6:ab:fc";
        hostname = "pki";
        ip = "192.168.20.5";
      };
    }
    {
      isVM = true;
      name = "home";
      platform = "x86_64-linux";
      stateVersion = "26.05";
      upsHost = "prx1-lab";
      proxNode = "prx2-lab";
      localDnsAliases = [ "home" ];
      cores = 4;
      memorySize = 8;
      diskSize = 80;
      sshPort = 10011;
      hmFull = false;
      dhcpReservation = {
        match = "02:48:4f:4d:45:01";
        hostname = "home";
        ip = "192.168.20.6";
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

  secretDomainsByHost =
    (lib.mapAttrs' (
      name: spec: lib.nameValuePair (spec.hostname or name) (toSecretDomain spec)
    ) darwinHosts)
    // builtins.listToAttrs (
      map (spec: {
        name = toNixosRuntimeHostName spec;
        value = toSecretDomain spec;
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
