{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  paperlessService = hostInventory.servicesById.paperless;
  beastNfsAddress = hostInventory.toNixosHostIpv4Address "beast";
  paperlessStoragePath = "/data/paperless";
  paperlessGptStateDir = "/var/lib/paperless-gpt";
  ollamaTunnelPort = 11435;
  ollamaInternalHost = "ollama.${hostInventory.site.lan.domain}";
  ociImages = builtins.fromJSON (builtins.readFile ../../lib/oci-images.json);
  paperlessGptImage = "${ociImages.paperless-gpt.image}:${ociImages.paperless-gpt.tag}";

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

  bootstrapScript = pkgs.writeText "paperless-bootstrap.py" ''
    import os
    import pathlib

    from django.contrib.auth import get_user_model
    from rest_framework.authtoken.models import Token

    def read_secret(path):
      return pathlib.Path(path).read_text().strip()

    User = get_user_model()

    users = [
      {
        "username": "ihar",
        "email": "ihar.hrachyshka@gmail.com",
        "password_file": os.environ["PAPERLESS_IHAR_PASSWORD_FILE"],
        "is_staff": True,
        "is_superuser": True,
      },
      {
        "username": "kasia",
        "email": "",
        "password_file": os.environ["PAPERLESS_KASIA_PASSWORD_FILE"],
        "is_staff": True,
        "is_superuser": True,
      },
    ]

    for spec in users:
      user, _ = User.objects.get_or_create(
        username=spec["username"],
        defaults={
          "email": spec["email"],
          "is_staff": spec["is_staff"],
          "is_superuser": spec["is_superuser"],
        },
      )
      changed = False
      for field in ["email", "is_staff", "is_superuser"]:
        if getattr(user, field) != spec[field]:
          setattr(user, field, spec[field])
          changed = True
      password = read_secret(spec["password_file"])
      if not user.check_password(password):
        user.set_password(password)
        changed = True
      if changed:
        user.save()

    token_key = read_secret(os.environ["PAPERLESS_GPT_API_TOKEN_FILE"])
    if len(token_key) != 40:
      raise SystemExit("PAPERLESS_GPT_API_TOKEN must be a 40-character Django REST token")

    admin = User.objects.get(username="ihar")
    existing = Token.objects.filter(user=admin).first()
    if existing is None:
      Token.objects.create(user=admin, key=token_key)
    elif existing.key != token_key:
      existing.delete()
      Token.objects.create(user=admin, key=token_key)
  '';
in
{
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
        "podman-paperless-gpt.service"
      ];
    };
    "internal-https-client-ollama-crt" = {
      key = "internal_https/clients/ollama/client_crt_unencrypted";
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "stunnel.service" ];
    };
    "internal-https-client-ollama-key" = {
      key = "internal_https/clients/ollama/client_key";
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "stunnel.service" ];
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

  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    database.createLocally = true;
    domain = paperlessService.publicHost;
    mediaDir = "${paperlessStoragePath}/media";
    consumptionDir = "${paperlessStoragePath}/consume";
    passwordFile = config.sops.secrets."paperless/admin/password".path;
    settings = {
      PAPERLESS_ADMIN_USER = "ihar";
      PAPERLESS_ADMIN_MAIL = "ihar.hrachyshka@gmail.com";
      PAPERLESS_ACCOUNT_ALLOW_SIGNUPS = false;
      PAPERLESS_ALLOWED_HOSTS = lib.concatStringsSep "," [
        paperlessService.publicHost
        "paperless.${hostInventory.site.lan.domain}"
        "paperless.local"
        "127.0.0.1"
        "localhost"
      ];
      PAPERLESS_CSRF_TRUSTED_ORIGINS = paperlessService.url;
      PAPERLESS_CONSUMER_IGNORE_PATTERN = lib.concatStringsSep "," [
        ".DS_STORE/*"
        "desktop.ini"
      ];
      PAPERLESS_OCR_LANGUAGE = "eng";
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
      before = [ "podman-paperless-gpt.service" ];
      unitConfig.RequiresMountsFor = [ config.services.paperless.dataDir ];
      path = [ config.services.paperless.manage ];
      serviceConfig = {
        Type = "oneshot";
        User = "paperless";
        Group = "paperless";
        Environment = [
          "PAPERLESS_IHAR_PASSWORD_FILE=${config.sops.secrets."paperless/admin/password".path}"
          "PAPERLESS_KASIA_PASSWORD_FILE=${config.sops.secrets."paperless/users/kasia/password".path}"
          "PAPERLESS_GPT_API_TOKEN_FILE=${config.sops.secrets."paperless/api/token".path}"
        ];
      };
      script = ''
        paperless-manage shell -c 'exec(open("${bootstrapScript}").read())'
      '';
    };

    podman-paperless-gpt = {
      wants = [
        "network-online.target"
        "paperless-bootstrap.service"
        "paperless-web.service"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      after = [
        "network-online.target"
        "paperless-bootstrap.service"
        "paperless-web.service"
        "sops-install-secrets.service"
        "stunnel.service"
      ];
      unitConfig.RequiresMountsFor = [ paperlessGptStateDir ];
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
      "d '${paperlessGptStateDir}/config' 0750 root root - -"
      "d '${paperlessGptStateDir}/hocr' 0750 root root - -"
      "d '${paperlessGptStateDir}/pdf' 0750 root root - -"
      "d '${paperlessGptStateDir}/prompts' 0750 root root - -"
    ];
  };

  host.internalHttps.services.paperless = {
    enable = true;
    upstream = "http://127.0.0.1:${toString config.services.paperless.port}";
    serverAliases = [ paperlessService.publicHost ];
    mtls.enable = true;
    locationExtraConfig = ''
      client_max_body_size 512m;
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
    '';
  };

  host.externalService.mtlsClients.ollama = {
    enable = true;
    commonName = "ollama.org";
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
      pull = "missing";
      environment = {
        AUTO_GENERATE_CORRESPONDENTS = "true";
        AUTO_GENERATE_CREATED_DATE = "true";
        AUTO_GENERATE_DOCUMENT_TYPE = "true";
        AUTO_GENERATE_TAGS = "true";
        AUTO_GENERATE_TITLE = "true";
        AUTO_OCR_TAG = "paperless-gpt-ocr-auto";
        CREATE_LOCAL_HOCR = "false";
        CREATE_LOCAL_PDF = "false";
        LLM_LANGUAGE = "English";
        LLM_MODEL = "qwen3:14b";
        LLM_PROVIDER = "ollama";
        LISTEN_INTERFACE = "127.0.0.1:8080";
        LOCAL_HOCR_PATH = "/app/hocr";
        LOCAL_PDF_PATH = "/app/pdf";
        LOG_LEVEL = "info";
        OCR_LIMIT_PAGES = "5";
        OCR_PROCESS_MODE = "image";
        OCR_PROVIDER = "llm";
        OLLAMA_CONTEXT_LENGTH = "8192";
        OLLAMA_HOST = "http://127.0.0.1:${toString ollamaTunnelPort}";
        PAPERLESS_BASE_URL = "http://127.0.0.1:${toString config.services.paperless.port}";
        PAPERLESS_PUBLIC_URL = paperlessService.url;
        PDF_COPY_METADATA = "true";
        PDF_OCR_TAGGING = "true";
        PDF_REPLACE = "false";
        PDF_SKIP_EXISTING_OCR = "false";
        PDF_UPLOAD = "false";
        TOKEN_LIMIT = "2000";
        VISION_LLM_MODEL = "minicpm-v:8b";
        VISION_LLM_PROVIDER = "ollama";
      };
      environmentFiles = [ config.sops.templates."paperless-gpt.env".path ];
      extraOptions = [
        "--cap-drop=all"
        "--network=host"
        "--security-opt=no-new-privileges"
      ];
      volumes = [
        "${paperlessGptStateDir}/config:/app/config:rw"
        "${paperlessGptStateDir}/hocr:/app/hocr:rw"
        "${paperlessGptStateDir}/pdf:/app/pdf:rw"
        "${paperlessGptStateDir}/prompts:/app/prompts:rw"
      ];
    };
  };
}
