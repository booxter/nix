{
  config,
  hostInventory,
  lib,
  orgPkgs,
  pkgs,
  utils,
  ...
}:
let
  paperlessService = hostInventory.servicesById.paperless;
  paperlessGptService = hostInventory.servicesById."paperless-gpt";
  beastNfsAddress = hostInventory.toNixosHostIpv4Address "beast";
  paperlessMetricsInternalPort = 19289;
  paperlessMetricsMtlsPort = 9348;
  paperlessStoragePath = "/data/paperless";
  paperlessGptStateDir = "/var/lib/paperless-gpt";
  paperlessGptAutoTag = "paperless-gpt-auto";
  paperlessGptAutoOcrTag = "paperless-gpt-ocr-auto";
  paperlessGptOcrCompleteTag = "paperless-gpt-ocr-complete";
  paperlessGptContainerUid = "10001";
  paperlessGptContainerGid = "10001";
  paperlessGptPort = 8080;
  paperlessGptHost = "${paperlessGptService.id}.${hostInventory.site.lan.domain}";
  paperlessGptOauth2ProxyPort = 4181;
  oidcClient = config.host.sso.oidc.clients.paperless;
  oidcScopes = config.host.sso.oidc.baseScopes;
  paperlessOidcProviderId = "sso";
  paperlessOidcClientSecretPlaceholder = "__PAPERLESS_OIDC_CLIENT_SECRET__";
  paperlessOidcProvidersJson =
    builtins.replaceStrings
      [ paperlessOidcClientSecretPlaceholder ]
      [
        oidcClient.secret.placeholder
      ]
      (
        builtins.toJSON {
          openid_connect.APPS = [
            {
              provider_id = paperlessOidcProviderId;
              name = "SSO";
              client_id = oidcClient.clientId;
              secret = paperlessOidcClientSecretPlaceholder;
              settings = {
                email_authentication = true;
                oauth_pkce_enabled = true;
                server_url = oidcClient.discoveryUrl;
                token_auth_method = "client_secret_basic";
                verified_email = true;
                scope = oidcScopes ++ [ "groups" ];
              };
            }
          ];
        }
      );
  ollamaTunnelPort = 11435;
  ollamaInternalHost = "ollama.${hostInventory.site.lan.domain}";
  ociImages = import ../../lib/oci-images { inherit pkgs; };
  paperlessGptImage = ociImages.paperless-gpt.ref;
  paperlessGptImageFile = ociImages.paperless-gpt.imageFile;

  nfsMountOptions = [
    "nfsvers=4"
    "hard"
    "nofail"
    "_netdev"
    "noatime"
    "x-systemd.automount"
    "x-systemd.idle-timeout=0"
    "x-systemd.mount-timeout=30s"
    "x-systemd.requires=network-online.target"
    "x-systemd.after=network-online.target"
  ];

  paperlessNfsPaths = [
    "${paperlessStoragePath}/consume"
    "${paperlessStoragePath}/export"
    "${paperlessStoragePath}/media"
  ];
  paperlessBootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' config.services.paperless.manage "paperless-manage")
    "shell"
    "-c"
    "from paperless_bootstrap.django import main; main()"
  ];

in
{
  host.sso.oidc.registrations.paperless = {
    displayName = "Paperless";
    originUrls = [ "${paperlessService.url}/accounts/oidc/sso/login/callback/" ];
    originLanding = "${paperlessService.url}/";
    scopeMaps = {
      "paperless-admins" = oidcScopes ++ [ "groups" ];
      "paperless-users" = oidcScopes ++ [ "groups" ];
    };
    claimMaps.groups.valuesByGroup = {
      "paperless-admins" = [ "paperless-admins" ];
      "paperless-users" = [ "paperless-users" ];
    };
    secret = {
      sopsKey = "paperless/oidc/client_secret";
      name = "paperless/oidc/client_secret";
      restartUnits = [
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-web.service"
      ];
    };
  };

  boot.supportedFilesystems = [ "nfs" ];

  fileSystems.${paperlessStoragePath} = {
    device = "${beastNfsAddress}:/volume2/paperless";
    fsType = "nfs";
    options = nfsMountOptions;
  };

  virtualisation.vmVariant.virtualisation.fileSystems.${paperlessStoragePath} = {
    device = "${beastNfsAddress}:/volume2/paperless";
    fsType = "nfs";
    options = nfsMountOptions;
  };

  sops.secrets = {
    "paperless/admin/password" = {
      owner = "paperless";
      group = "paperless";
      mode = "0400";
      restartUnits = [
        "paperless-bootstrap.service"
        "paperless-scheduler.service"
      ];
    };
    "paperless/users/kasia/password" = {
      owner = "paperless";
      group = "paperless";
      mode = "0400";
      restartUnits = [ "paperless-bootstrap.service" ];
    };
    "paperless/api/token" = {
      owner = "paperless";
      group = "paperless";
      mode = "0400";
      restartUnits = [
        "paperless-bootstrap.service"
        "paperless-gpt-configure.service"
        "prometheus-paperless-exporter.service"
        "podman-paperless-gpt.service"
      ];
    };
  };

  sops.templates."paperless-gpt.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      PAPERLESS_API_TOKEN=${config.sops.placeholder."paperless/api/token"}
    '';
    restartUnits = [ "podman-paperless-gpt.service" ];
  };

  sops.templates."paperless-oidc.env" = {
    owner = "paperless";
    group = "paperless";
    mode = "0400";
    content = ''
      PAPERLESS_SOCIALACCOUNT_PROVIDERS='${paperlessOidcProvidersJson}'
    '';
    restartUnits = [
      "paperless-scheduler.service"
      "paperless-task-queue.service"
      "paperless-web.service"
    ];
  };

  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    database.createLocally = true;
    domain = paperlessService.publicHost;
    environmentFile = config.sops.templates."paperless-oidc.env".path;
    mediaDir = "${paperlessStoragePath}/media";
    consumptionDir = "${paperlessStoragePath}/consume";
    passwordFile = config.sops.secrets."paperless/admin/password".path;
    settings = {
      PAPERLESS_ADMIN_USER = "ihar";
      PAPERLESS_ADMIN_MAIL = "ihar.hrachyshka@gmail.com";
      PAPERLESS_ACCOUNT_ALLOW_SIGNUPS = false;
      PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
      PAPERLESS_ALLOWED_HOSTS = lib.concatStringsSep "," [
        paperlessService.publicHost
        "paperless.${hostInventory.site.lan.domain}"
        "paperless.local"
        "127.0.0.1"
        "localhost"
      ];
      PAPERLESS_CSRF_TRUSTED_ORIGINS = paperlessService.url;
      PAPERLESS_DISABLE_REGULAR_LOGIN = false;
      PAPERLESS_CONSUMER_IGNORE_PATTERN = lib.concatStringsSep "," [
        ".DS_STORE/*"
        "desktop.ini"
      ];
      PAPERLESS_OCR_LANGUAGE = "eng";
      PAPERLESS_REDIRECT_LOGIN_TO_SSO = false;
      PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = false;
      PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS = true;
      PAPERLESS_SOCIAL_AUTO_SIGNUP = false;
    };
  };

  systemd.services = {
    paperless-scheduler.unitConfig.RequiresMountsFor = paperlessNfsPaths;
    paperless-consumer.unitConfig.RequiresMountsFor = paperlessNfsPaths;
    paperless-task-queue.unitConfig.RequiresMountsFor = paperlessNfsPaths;
    paperless-web.unitConfig.RequiresMountsFor = paperlessNfsPaths;

    paperless-bootstrap = {
      description = "Apply declarative Paperless users and API token";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "paperless-scheduler.service"
        "sops-install-secrets.service"
      ];
      after = [
        "paperless-scheduler.service"
        "sops-install-secrets.service"
      ];
      before = [
        "paperless-gpt-configure.service"
        "podman-paperless-gpt.service"
      ];
      unitConfig.RequiresMountsFor = [ config.services.paperless.dataDir ];
      serviceConfig = {
        Type = "oneshot";
        User = "paperless";
        Group = "paperless";
        Environment = [
          "PAPERLESS_IHAR_PASSWORD_FILE=${config.sops.secrets."paperless/admin/password".path}"
          "PAPERLESS_KASIA_PASSWORD_FILE=${config.sops.secrets."paperless/users/kasia/password".path}"
          "PAPERLESS_GPT_API_TOKEN_FILE=${config.sops.secrets."paperless/api/token".path}"
          "PYTHONPATH=${orgPkgs.paperless-bootstrap}/${orgPkgs.paperless-bootstrap.python.sitePackages}"
        ];
        # The upstream NixOS module exposes administration through Django's
        # `shell -c` subcommand; this argument is Python, not a POSIX shell.
        ExecStart = paperlessBootstrapCommand;
      };
    };

    paperless-gpt-configure = {
      description = "Configure Paperless workflow for paperless-gpt";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "paperless-bootstrap.service"
        "paperless-web.service"
        "sops-install-secrets.service"
      ];
      after = [
        "paperless-bootstrap.service"
        "paperless-web.service"
        "sops-install-secrets.service"
      ];
      before = [ "podman-paperless-gpt.service" ];
      environment = {
        PAPERLESS_API_TOKEN_FILE = config.sops.secrets."paperless/api/token".path;
        PAPERLESS_BASE_URL = "http://127.0.0.1:${toString config.services.paperless.port}";
        PAPERLESS_GPT_AUTO_TAG = paperlessGptAutoTag;
        PAPERLESS_GPT_AUTO_OCR_TAG = paperlessGptAutoOcrTag;
        PAPERLESS_GPT_OCR_COMPLETE_TAG = paperlessGptOcrCompleteTag;
        PAPERLESS_GPT_AUTO_OCR_WORKFLOW_NAME = "Auto OCR with paperless-gpt";
        PAPERLESS_GPT_POST_OCR_WORKFLOW_NAME = "Auto classify after paperless-gpt OCR";
      };
      serviceConfig = {
        Type = "oneshot";
        User = "paperless";
        Group = "paperless";
        ExecStart = lib.getExe orgPkgs.paperless-gpt-configure;
      };
    };

    podman-paperless-gpt = {
      wants = [
        "network-online.target"
        "paperless-bootstrap.service"
        "paperless-gpt-configure.service"
        "paperless-web.service"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      after = [
        "network-online.target"
        "paperless-bootstrap.service"
        "paperless-gpt-configure.service"
        "paperless-web.service"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      unitConfig.RequiresMountsFor = [ paperlessGptStateDir ];
    };

    prometheus-paperless-exporter = {
      description = "Prometheus exporter for Paperless-ngx";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "paperless-web.service"
        "sops-install-secrets.service"
      ];
      after = [
        "paperless-web.service"
        "sops-install-secrets.service"
      ];
      environment = {
        PAPERLESS_URL = "http://127.0.0.1:${toString config.services.paperless.port}";
        PAPERLESS_AUTH_TOKEN_FILE = config.sops.secrets."paperless/api/token".path;
      };
      serviceConfig = {
        User = "paperless";
        Group = "paperless";
        ExecStart = "${lib.getExe orgPkgs.prometheus-paperless-exporter} --collectors=status,statistics,document --web.disable-exporter-metrics --web.listen-address=127.0.0.1:${toString paperlessMetricsInternalPort}";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };
  };

  systemd.tmpfiles = {
    # Paperless' upstream module would create media/consume here too; those
    # paths live on NFS and are owned/created by beast.
    settings."10-paperless" = lib.mkForce {
      "${config.services.paperless.dataDir}".d = {
        user = config.services.paperless.user;
        group = config.users.users.${config.services.paperless.user}.group;
      };
    };
    rules = [
      "d '${paperlessGptStateDir}' 0750 root root - -"
      "d '${paperlessGptStateDir}/config' 0750 ${paperlessGptContainerUid} ${paperlessGptContainerGid} - -"
      "d '${paperlessGptStateDir}/db' 0750 ${paperlessGptContainerUid} ${paperlessGptContainerGid} - -"
      "d '${paperlessGptStateDir}/hocr' 0750 ${paperlessGptContainerUid} ${paperlessGptContainerGid} - -"
      "d '${paperlessGptStateDir}/home' 0750 ${paperlessGptContainerUid} ${paperlessGptContainerGid} - -"
      "d '${paperlessGptStateDir}/pdf' 0750 ${paperlessGptContainerUid} ${paperlessGptContainerGid} - -"
      "d '${paperlessGptStateDir}/prompts' 0750 ${paperlessGptContainerUid} ${paperlessGptContainerGid} - -"
    ];
  };

  host.internalHttps.services.paperless = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.paperless.port}";
    publicAliases = [ paperlessService.publicHost ];
    mtls.enable = true;
    recommendedProxySettings = false;
    locationExtraConfig = ''
      client_max_body_size 512m;
      proxy_set_header Host ${paperlessService.publicHost};
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host ${paperlessService.publicHost};
      proxy_set_header X-Forwarded-Server $hostname;
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
    '';
  };

  host.internalHttps.services.paperless-gpt = {
    enable = true;
    upstream = "http://127.0.0.1:${toString paperlessGptPort}";
  };

  host.sso.oauth2ProxyGates.paperless-gpt = {
    enable = true;
    clientId = "paperless-gpt";
    httpAddress = "http://127.0.0.1:${toString paperlessGptOauth2ProxyPort}";
    cookieName = "_paperless_gpt_sso";
    allowedGroups = [ "paperless-admins" ];
    groupClaim = "paperless_groups";
    whitelistDomains = [ paperlessGptHost ];
    internalHttpsServiceNames = [ "paperless-gpt" ];
    authCookieVariableName = "paperless_gpt_auth_cookie";
    probeLocationsByName.paperless-gpt."= /api/version" = {
      proxyPass = "http://127.0.0.1:${toString paperlessGptPort}";
      recommendedProxySettings = true;
      extraConfig = ''
        auth_request off;
      '';
    };
  };

  host.observability.client.prometheusMtlsEndpoints.paperless = {
    enable = true;
    port = paperlessMetricsMtlsPort;
    upstream = "http://127.0.0.1:${toString paperlessMetricsInternalPort}/metrics";
  };

  host.internalHttps.mtlsClients.ollama = {
    enable = true;
    commonName = "ollama.org";
    restartUnits = [ "stunnel.service" ];
  };

  services.stunnel = {
    enable = true;
    logLevel = lib.mkDefault "warning";
    user = null;
    group = null;
    clients.ollama = {
      accept = "127.0.0.1:${toString ollamaTunnelPort}";
      connect = "${ollamaInternalHost}:443";
      cert = config.sops.secrets."internal-https-client-ollama-crt".path;
      key = config.sops.secrets."internal-https-client-ollama-key".path;
      checkHost = ollamaInternalHost;
      sni = ollamaInternalHost;
      CAFile = toString (import ../../lib/home-internal-pki-root-ca.nix);
      verifyChain = true;
      OCSPaia = false;
    };
  };

  systemd.services.stunnel = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };

  virtualisation.oci-containers = {
    backend = "podman";
    containers.paperless-gpt = {
      image = paperlessGptImage;
      imageFile = paperlessGptImageFile;
      pull = "never";
      entrypoint = "/app/paperless-gpt";
      user = "${paperlessGptContainerUid}:${paperlessGptContainerGid}";
      capabilities.all = false;
      environment = {
        AUTO_GENERATE_CORRESPONDENTS = "true";
        AUTO_GENERATE_CREATED_DATE = "true";
        AUTO_GENERATE_DOCUMENT_TYPE = "true";
        # paperless-gpt may re-suggest OCR control tags, while the
        # completion-tag guard is still broken:
        # https://github.com/icereed/paperless-gpt/issues/1006
        AUTO_GENERATE_TAGS = "false";
        AUTO_GENERATE_TITLE = "true";
        AUTO_OCR_TAG = paperlessGptAutoOcrTag;
        AUTO_TAG = paperlessGptAutoTag;
        AUTO_TAG_COMPLETE = "";
        CREATE_LOCAL_HOCR = "false";
        CREATE_LOCAL_PDF = "false";
        CREATE_NEW_TAGS = "false";
        FAIL_TAG = "paperless-gpt-failed";
        HOME = "/home/paperless-gpt";
        LLM_LANGUAGE = "English";
        LLM_MODEL = "granite4:32b-a9b-h";
        LLM_PROVIDER = "ollama";
        LISTEN_INTERFACE = "127.0.0.1:${toString paperlessGptPort}";
        LOCAL_HOCR_PATH = "/app/hocr";
        LOCAL_PDF_PATH = "/app/pdf";
        LOG_LEVEL = "info";
        OCR_LIMIT_PAGES = "5";
        OCR_MAX_RETRIES = "3";
        OCR_PROCESS_MODE = "image";
        OCR_PROVIDER = "llm";
        OLLAMA_CONTEXT_LENGTH = "8192";
        OLLAMA_HOST = "http://127.0.0.1:${toString ollamaTunnelPort}";
        OLLAMA_THINK = "false";
        PAPERLESS_BASE_URL = "http://127.0.0.1:${toString config.services.paperless.port}";
        PAPERLESS_PUBLIC_URL = paperlessService.url;
        PDF_COPY_METADATA = "true";
        PDF_OCR_COMPLETE_TAG = paperlessGptOcrCompleteTag;
        PDF_OCR_TAGGING = "true";
        PDF_REPLACE = "false";
        PDF_SKIP_EXISTING_OCR = "false";
        PDF_UPLOAD = "false";
        TOKEN_LIMIT = "2000";
        VISION_LLM_MODEL = "qwen3-vl:8b-instruct";
        VISION_LLM_PROVIDER = "ollama";
      };
      environmentFiles = [ config.sops.templates."paperless-gpt.env".path ];
      networks = [ "host" ];
      extraOptions = [
        # Bypass upstream's root entrypoint; it recursively chowns /app and
        # needs extra capabilities. Host tmpfiles owns writable state instead.
        "--security-opt=no-new-privileges"
      ];
      volumes = [
        "${paperlessGptStateDir}/config:/app/config:rw"
        "${paperlessGptStateDir}/db:/app/db:rw"
        "${paperlessGptStateDir}/hocr:/app/hocr:rw"
        "${paperlessGptStateDir}/home:/home/paperless-gpt:rw"
        "${paperlessGptStateDir}/pdf:/app/pdf:rw"
        "${paperlessGptStateDir}/prompts:/app/prompts:rw"
      ];
    };
  };
}
