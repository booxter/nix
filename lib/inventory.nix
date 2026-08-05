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
      isBuilder = true;
      isVM = true;
      name = "builder${idx'}";
      platform = "x86_64-linux";
      proxNode = "prx${idx'}-lab";
      dhcpReservation = builderDhcpReservations.${idx'};
      stateVersion = "25.11";
      memorySize = 64;
      balloonSize = 48;
      diskSize = 150;
      cores = 24;
      hmFull = false;
      nspawnTestBuilder = true;
      resourceControl.diskSwapGiB = 8;
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

  normalizeService =
    hostSpecsByName: localDnsName:
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
    let
      service = {
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
      ownerSpec = hostSpecsByName.${owner};
      resolvedService =
        service
        // lib.optionalAttrs (service ? publicHost) (rec {
          inherit (service) publicHost;
          url = "https://${publicHost}";
          probeUrl = "${url}${service.probePath}";
        })
        // lib.optionalAttrs (service.scope == "internal") {
          displayHost = localDnsName ownerSpec.name;
          probeHost = ownerSpec.name;
        };
      category = service.glanceCategory or null;
      categoryLabel = if category == null then "<missing>" else category;
    in
    assert lib.asserts.assertMsg (
      !service.showInGlance || category != null
    ) "Glance service ${service.id} must set glanceCategory";
    assert lib.asserts.assertMsg (
      category == null || builtins.elem category glanceCategoryIds
    ) "Glance service ${service.id} uses unknown glanceCategory '${categoryLabel}'";
    resolvedService;

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
              lib.unique (spec.localDnsAliases or [ ])
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
      "trilium-users" = {
        title = "Trilium Notes users";
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
        mailAddressSopsKey = "kanidm/person_mail_addresses/ihar";
        groups = [
          "sso-admins"
          "infra-admins"
          "grafana-admins"
          "home-admins"
          "home-users"
          "paperless-admins"
          "paperless-users"
          "vikunja-users"
          "trilium-users"
          "ai-users"
          "romm-admins"
          "media-admins"
          "media-users"
        ];
      };
      kasia = {
        displayName = "kasia";
        mailAddressSopsKey = "kanidm/person_mail_addresses/kasia";
        groups = [
          "paperless-users"
          "vikunja-users"
          "ai-users"
          "media-admins"
          "media-users"
          "romm-viewers"
          "home-users"
        ];
      };
      eugene = {
        displayName = "eugene";
        mailAddressSopsKey = "kanidm/person_mail_addresses/eugene";
        groups = [
          "ai-users"
          "media-users"
          "vikunja-users"
          "romm-viewers"
        ];
      };
      oidc-probe-user = {
        displayName = "OIDC synthetic probe";
        mailAddressSopsKey = "kanidm/person_mail_addresses/oidc-probe-user";
        groups = [
          "oidc-probe-users"
          "search-probe-users"
        ];
      };
    };
  };

  services = map (normalizeService nixosHostSpecsByName toLocalDnsName) [
    {
      id = "id";
      title = "SSO";
      icon = "sh:kanidm";
      scope = "external";
      owner = "pki";
      publicHost = "id.${site.public.domain}";
      probePath = "/status";
      showInGlance = false;
    }
    {
      id = "dash";
      title = "Dashboard";
      icon = "sh:glance";
      scope = "external";
      owner = "srvarr";
      publicHost = "dash.${site.public.domain}";
      probePath = "/";
      showInGlance = false;
    }
    {
      id = "jellyfin";
      scope = "external";
      owner = "beast";
      publicHost = "jf.${site.public.domain}";
      probePath = "/web/";
      glanceCategory = "user";
    }
    {
      id = "jfstat";
      title = "Jellystat";
      icon = "di:jellystat";
      scope = "internal";
      owner = "beast";
      probePath = "/auth/isConfigured";
      glanceCategory = "media-admin";
    }
    {
      id = "watchstate";
      title = "WatchState";
      icon = "sh:watchstate.png";
      scope = "internal";
      owner = "beast";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/v1/api/system/healthcheck";
      glanceCategory = "media-admin";
    }
    {
      id = "seerr";
      scope = "external";
      owner = "srvarr";
      publicHost = "js.${site.public.domain}";
      probePath = "/login";
      glanceCategory = "user";
    }
    {
      id = "romm";
      title = "RomM";
      scope = "external";
      owner = "srvarr";
      publicHost = "game.${site.public.domain}";
      probePath = "/api/heartbeat";
      glanceCategory = "user";
    }
    {
      id = "grafana";
      scope = "internal";
      owner = "fana";
      probePath = "/login";
      glanceCategory = "infrastructure";
    }
    {
      id = "home";
      title = "Home Assistant";
      icon = "sh:home-assistant";
      scope = "internal";
      owner = "home";
      probePath = "/";
      glanceCategory = "infrastructure";
    }
    {
      id = "houndarr";
      icon = "sh:houndarr.png";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health";
      glanceCategory = "media-admin";
    }
    {
      id = "radarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "sonarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "lidarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "letterboxd-list-radarr";
      title = "Letterboxd Radarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/";
      showInGlance = false;
    }
    {
      id = "aurral";
      scope = "external";
      owner = "srvarr";
      publicHost = "mu.${site.public.domain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health/live";
      glanceCategory = "user";
    }
    {
      id = "audiobookshelf";
      scope = "external";
      owner = "srvarr";
      publicHost = "au.${site.public.domain}";
      probePath = "";
      glanceCategory = "user";
    }
    {
      id = "pinepods";
      title = "PinePods";
      icon = "https://raw.githubusercontent.com/madeofpendletonwool/PinePods/0.9.0/images/icon-192.png";
      scope = "external";
      owner = "srvarr";
      publicHost = "pod.${site.public.domain}";
      probePath = "/api/health";
      glanceCategory = "user";
    }
    {
      id = "shelfmark";
      scope = "external";
      owner = "srvarr";
      publicHost = "shelf.${site.public.domain}";
      probePath = "/api/health";
      glanceCategory = "user";
    }
    {
      id = "vikunja";
      scope = "external";
      owner = "org";
      publicHost = "vi.${site.public.domain}";
      probePath = "";
      glanceCategory = "user";
    }
    {
      id = "notes";
      title = "Trilium Notes";
      icon = "sh:trilium-notes";
      scope = "external";
      owner = "org";
      publicHost = "notes.${site.public.domain}";
      probePath = "/authenticate";
      backendProbe.path = "/api/health-check";
      glanceCategory = "infrastructure";
    }
    {
      id = "paperless";
      title = "Paperless";
      icon = "sh:paperless-ngx";
      scope = "external";
      owner = "org";
      publicHost = "papers.${site.public.domain}";
      probePath = "/accounts/login/";
      glanceCategory = "infrastructure";
    }
    {
      id = "paperless-gpt";
      title = "Paperless GPT";
      icon = "sh:paperless-ngx";
      scope = "internal";
      owner = "org";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/version";
      glanceCategory = "infrastructure";
    }
    {
      id = "llm";
      title = "LLM Gateway";
      icon = "sh:litellm";
      scope = "external";
      owner = "org";
      publicHost = "llm.${site.public.domain}";
      probePath = "/health/liveliness";
      glanceCategory = "infrastructure";
    }
    {
      id = "ai";
      title = "Open WebUI";
      icon = "sh:open-webui";
      scope = "external";
      owner = "org";
      publicHost = "ai.${site.public.domain}";
      probePath = "/";
      glanceCategory = "user";
    }
    {
      id = "search";
      title = "Search";
      icon = "sh:searxng";
      scope = "external";
      owner = "org";
      publicHost = "search.${site.public.domain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/healthz";
      glanceCategory = "user";
    }
    {
      id = "goo";
      title = "Degoog";
      icon = "https://raw.githubusercontent.com/degoog-org/degoog/0.23.0/src/public/images/degoog-logo.png";
      scope = "external";
      owner = "org";
      publicHost = "goo.${site.public.domain}";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/readyz";
      glanceCategory = "user";
    }
    {
      id = "tg";
      title = "Telegram Archive";
      icon = "sh:telegram";
      scope = "internal";
      owner = "org";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/health";
      glanceCategory = "infrastructure";
    }
    {
      id = "ollama";
      title = "Ollama";
      scope = "internal";
      owner = "frame";
      probePath = "/";
      blackboxProbe = false;
      showInGlance = false;
    }
    {
      id = "bazarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/api/system/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "prowlarr";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/ping";
      glanceCategory = "media-admin";
    }
    {
      id = "transmission";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe = {
        path = "/__probe/transmission-rpc";
        blackboxModule = "http_service_409";
      };
      glanceCategory = "media-admin";
    }
    {
      id = "sabnzbd";
      title = "SABNZB";
      icon = "https://raw.githubusercontent.com/sabnzbd/sabnzbd/70d5134d28a0c1cddff49c97fa013cb67c356f9e/icons/logo-arrow.svg";
      scope = "internal";
      owner = "srvarr";
      probePath = "/oauth2/sign_in";
      backendProbe.path = "/__probe/sabnzbd-version";
      glanceCategory = "media-admin";
    }
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
      vnc.enable = true;
      hardware.gpuFamilies = [ "apple" ];
      lanWanInterfaces = [ "en0" ];
    };
    mmini = {
      stateVersion = 5;
      hmStateVersion = "25.11";
      hostname = "mmini";
      platform = "aarch64-darwin";
      isBuilder = true;
      isDesktop = true;
      vnc.enable = true;
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
      isBuilder = true;
      isDesktop = true;
      nspawnTestBuilder = true;
      sshTicket.allowX11Forwarding = true;
      localDnsAliases = [ "ollama" ];
      resourceControl.diskSwapGiB = 8;
      resourceControl.systemServices = {
        lightweight = [
          "fana-alertmanager-watchdog"
          "frame-amdgpu-metrics"
          "frame-ollama-metrics"
          "ollama-model-loader"
          "prometheus-blackbox-exporter"
          "prometheus-node-exporter"
        ];
        heavy.ollama = {
          memoryHigh = "80%";
          memoryMax = "90%";
          memorySwapMax = "8G";
          tasksMax = 4096;
        };
      };
      resourceControl.userServices.lightweight = [
        "codex-warmer"
        "gmailctl-token-keepalive"
        "sync-git-mains"
      ];
      vnc = {
        enable = true;
        # ReFrame exposes one loopback listener per inventory display.
        sshTunnel = true;
        basePort = 5933;
      };
      hardware =
        let
          displayMode = {
            width = 3840;
            height = 2160;
            refreshRate = 60;
          };
          displayScale = 1.5;
          logicalDisplayWidth = builtins.floor (displayMode.width / displayScale);
          mkDisplay =
            {
              name,
              connector,
              x,
              primary ? false,
            }:
            let
              y = 0;
            in
            {
              inherit
                connector
                name
                primary
                ;
              scale = displayScale;
              mode = displayMode;
              logical = {
                inherit x y;
                width = logicalDisplayWidth;
                height = builtins.floor (displayMode.height / displayScale);
              };
            };
        in
        {
          gpuFamilies = [ "amd" ];
          # Shared display topology for the kernel, GDM, Hyprland, and ReFrame.
          drmCard = "card1";
          displays = [
            (mkDisplay {
              name = "left";
              connector = "DP-4";
              x = 0;
              primary = true;
            })
            (mkDisplay {
              name = "right";
              connector = "DP-2";
              x = logicalDisplayWidth;
            })
          ];
        };
      dhcpReservation = {
        match = "9c:bf:0d:00:fa:0a";
        hostname = "frame";
        ip = "192.168.11.228";
      };
    }
    {
      hostKind = "proxmox";
      name = nvws;
      platform = "x86_64-linux";
      inherit username;
      isBuilder = true;
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
      resourceControl.diskSwapGiB = 8;
      resourceControl.systemServices = {
        lightweight = [
          "beast-disk-bay-export"
          "beast-hba-export"
          "beast-md-sync-export"
          "jellarr"
          "jellyfin-exporter"
          "prometheus-node-exporter"
          "prometheus-smartctl-exporter"
          "restic-cloud-usage-export"
        ];
        critical = [
          "jellyfin"
          "nfs-server"
        ];
      };
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
      platform = "x86_64-linux";
      inherit username;
      stateVersion = prxStateVersion;
      proxmoxUpgradeTime = "Mon 03:50";
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
      platform = "x86_64-linux";
      inherit username;
      upsHost = "prx1-lab";
      stateVersion = prxStateVersion;
      proxmoxUpgradeTime = "Mon 04:20";
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
      platform = "x86_64-linux";
      inherit username;
      upsHost = "prx1-lab";
      stateVersion = prxStateVersion;
      proxmoxUpgradeTime = "Mon 04:50";
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
      platform = "x86_64-linux";
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
      resourceControl.diskSwapGiB = 8;
    }
    {
      isVM = true;
      name = "cache";
      platform = "x86_64-linux";
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
      resourceControl.diskSwapGiB = 4;
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
        # Ports allocated in AirVPN's forwarded-port control panel.
        forwardedPorts = {
          slskd = 13869;
          transmission = 45486;
        };
      };
      resourceControl.systemServices = {
        lightweight = [
          "audiobookshelf-backup-bootstrap"
          "audiobookshelf-oidc-bootstrap"
          "houndarr-status-collector"
          "jellyfin-upload-policy"
          "jellyfin-upload-policy-tc"
          "jellyfin-upload-policy-transmission"
          "letterboxd-list-radarr"
          "prometheus-node-exporter"
          "prometheus-sabnzbd-exporter"
          "transmission-collector"
          "transmission-prioritizer"
          "transmission-torrent-cleaner"
          "update-dynamic-ip"
          "wg-bridge-access"
          "wg-qos"
        ];
        medium = [
          "ebook-converter"
          "lidarr-cue-splitter"
        ];
      };
      cores = 16;
      memorySize = 32;
      resourceControl.diskSwapGiB = 4;
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
      resourceControl.systemServices = {
        lightweight = [
          "prometheus-blackbox-exporter"
          "prometheus-node-exporter"
          "prometheus-nut-exporter"
          "unpoller"
        ];
        critical = [ "alertmanager" ];
      };
      cores = 8;
      memorySize = 16;
      diskSize = 300;
      resourceControl.diskSwapGiB = 4;
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
      platform = "x86_64-linux";
      upsHost = "prx1-lab";
      resourceControl.systemServices.lightweight = [
        "prometheus-node-exporter"
        "prometheus-wireguard-exporter"
        "wg-qos"
      ];
      cores = 2;
      memorySize = 8;
      diskSize = 64;
      resourceControl.diskSwapGiB = 2;
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
        "notes"
        "paperless"
        "paperless-gpt"
        "llm"
        "ai"
        "search"
        "goo"
        "tg"
      ];
      resourceControl.systemServices.lightweight = [
        "open-webui-searxng-probe"
        "prometheus-node-exporter"
        "prometheus-paperless-exporter"
        "searchless-ngx-metrics"
      ];
      upsHost = "prx1-lab";
      cores = 4;
      memorySize = 16;
      diskSize = 80;
      resourceControl.diskSwapGiB = 4;
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
      resourceControl.systemServices = {
        lightweight = [
          "kanidm-mail-sender"
          "kanidm-mail-sender-bootstrap"
          "kanidm-oidc-probe-bootstrap"
          "kanidm-oidc-synthetic-probe"
          "kanidm-person-mail-provision"
          "pki-rotate"
          "pki-status-export"
          "prometheus-node-exporter"
          "unifi-sync"
          "uptimerobot-sync"
          "wg-home-dns-sync"
        ];
        critical = [
          "kanidm"
          "step-ca"
        ];
      };
      upsHost = "prx1-lab";
      cores = 2;
      memorySize = 4;
      diskSize = 50;
      resourceControl.diskSwapGiB = 2;
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
      resourceControl.systemServices = {
        lightweight = [
          "home-assistant-bootstrap"
          "home-assistant-native-backup"
          "prometheus-node-exporter"
        ];
        critical = [ "home-assistant" ];
      };
      cores = 4;
      memorySize = 8;
      diskSize = 80;
      resourceControl.diskSwapGiB = 2;
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

  systemsByHost =
    (lib.mapAttrs' (name: spec: lib.nameValuePair (spec.hostname or name) spec.platform) darwinHosts)
    // builtins.listToAttrs (
      map (spec: {
        name = toNixosRuntimeHostName spec;
        value = spec.platform;
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
