{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  backupJob = config.host.backups.destinationJob;
  paperlessService = hostInventory.servicesById.paperless;
  paperlessGptService = hostInventory.servicesById."paperless-gpt";
  isOwner = paperlessGptService.owner == config.networking.hostName;
  paperlessSso = hostInventory.sso.applications.paperless;
  llm = hostInventory.realms.${config.host.realm}.services.llm;
  stateDir = "/var/lib/paperless-gpt";
  autoTag = "paperless-gpt-auto";
  autoOcrTag = "paperless-gpt-ocr-auto";
  ocrCompleteTag = "paperless-gpt-ocr-complete";
  containerUid = "10001";
  containerGid = "10001";
  port = 8080;
  host = "${paperlessGptService.id}.${hostInventory.site.lan.domain}";
  oauth2ProxyPort = 4181;
  ollamaTunnelPort = 11435;
  ollamaClient = config.host.llm.clients.paperless-gpt;
  textModel = "granite4:32b-a9b-h";
  visionModel = "qwen3-vl:8b-instruct";
  ociImages = import ../../../../oci { inherit pkgs; };
  image = ociImages.paperless-gpt.ref;
  imageFile = ociImages.paperless-gpt.imageFile;
  configure = pkgs.callPackage ./packages/paperless-gpt-configure { };
in
{
  config = lib.mkIf isOwner {
    assertions = [
      {
        assertion = paperlessGptService.owner == paperlessService.owner;
        message = "Paperless GPT and Paperless must have the same service owner.";
      }
      {
        assertion = builtins.elem textModel llm.models;
        message = "The realm LLM provider must load the Paperless GPT text model ${textModel}.";
      }
      {
        assertion = builtins.elem visionModel llm.models;
        message = "The realm LLM provider must load the Paperless GPT vision model ${visionModel}.";
      }
    ];

    sops.secrets."paperless/api/token".restartUnits = [
      "paperless-gpt-configure.service"
      "podman-paperless-gpt.service"
    ];

    sops.templates."paperless-gpt.env" = {
      owner = "root";
      group = "root";
      mode = "0400";
      content = ''
        PAPERLESS_API_TOKEN=${config.sops.placeholder."paperless/api/token"}
      '';
      restartUnits = [ "podman-paperless-gpt.service" ];
    };

    systemd.services = {
      paperless-bootstrap.before = [
        "paperless-gpt-configure.service"
        "podman-paperless-gpt.service"
      ];

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
          PAPERLESS_GPT_AUTO_TAG = autoTag;
          PAPERLESS_GPT_AUTO_OCR_TAG = autoOcrTag;
          PAPERLESS_GPT_OCR_COMPLETE_TAG = ocrCompleteTag;
          PAPERLESS_GPT_AUTO_OCR_WORKFLOW_NAME = "Auto OCR with paperless-gpt";
          PAPERLESS_GPT_POST_OCR_WORKFLOW_NAME = "Auto classify after paperless-gpt OCR";
        };
        serviceConfig = {
          Type = "oneshot";
          User = "paperless";
          Group = "paperless";
          ExecStart = lib.getExe configure;
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
        unitConfig.RequiresMountsFor = [ stateDir ];
      };
    };

    systemd.tmpfiles.rules = [
      "d '${stateDir}' 0750 root root - -"
      "d '${stateDir}/config' 0750 ${containerUid} ${containerGid} - -"
      "d '${stateDir}/db' 0750 ${containerUid} ${containerGid} - -"
      "d '${stateDir}/hocr' 0750 ${containerUid} ${containerGid} - -"
      "d '${stateDir}/home' 0750 ${containerUid} ${containerGid} - -"
      "d '${stateDir}/pdf' 0750 ${containerUid} ${containerGid} - -"
      "d '${stateDir}/prompts' 0750 ${containerUid} ${containerGid} - -"
    ];

    host.internalService.services.paperless-gpt = {
      enable = true;
      upstream = "http://127.0.0.1:${toString port}";
    };

    host.sso.oauth2ProxyGates.paperless-gpt = {
      enable = true;
      clientId = "paperless-gpt";
      displayName = "Paperless GPT";
      originLanding = "https://${host}/";
      httpAddress = "http://127.0.0.1:${toString oauth2ProxyPort}";
      cookieName = "_paperless_gpt_sso";
      allowedGroups = [ paperlessSso.adminGroup ];
      groupClaim = "paperless_groups";
      whitelistDomains = [ host ];
      internalServiceNames = [ "paperless-gpt" ];
      authCookieVariableName = "paperless_gpt_auth_cookie";
      probeLocationsByName.paperless-gpt."= /api/version" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        recommendedProxySettings = true;
        extraConfig = ''
          auth_request off;
        '';
      };
    };

    host.llm.clients.paperless-gpt = {
      enable = true;
      identityName = "ollama";
      localPort = ollamaTunnelPort;
    };

    host.backups.jobs.${backupJob}.paths = [ stateDir ];

    virtualisation.oci-containers = {
      backend = "podman";
      containers.paperless-gpt = {
        inherit image imageFile;
        pull = "never";
        entrypoint = "/app/paperless-gpt";
        user = "${containerUid}:${containerGid}";
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
          AUTO_OCR_TAG = autoOcrTag;
          AUTO_TAG = autoTag;
          AUTO_TAG_COMPLETE = "";
          CREATE_LOCAL_HOCR = "false";
          CREATE_LOCAL_PDF = "false";
          CREATE_NEW_TAGS = "false";
          FAIL_TAG = "paperless-gpt-failed";
          HOME = "/home/paperless-gpt";
          LLM_LANGUAGE = hostInventory.regional.language.name;
          LLM_MODEL = textModel;
          LLM_PROVIDER = "ollama";
          LISTEN_INTERFACE = "127.0.0.1:${toString port}";
          LOCAL_HOCR_PATH = "/app/hocr";
          LOCAL_PDF_PATH = "/app/pdf";
          LOG_LEVEL = "info";
          OCR_LIMIT_PAGES = "5";
          OCR_MAX_RETRIES = "3";
          OCR_PROCESS_MODE = "image";
          OCR_PROVIDER = "llm";
          OLLAMA_CONTEXT_LENGTH = "8192";
          OLLAMA_HOST = ollamaClient.url;
          OLLAMA_THINK = "false";
          PAPERLESS_BASE_URL = "http://127.0.0.1:${toString config.services.paperless.port}";
          PAPERLESS_PUBLIC_URL = paperlessService.url;
          PDF_COPY_METADATA = "true";
          PDF_OCR_COMPLETE_TAG = ocrCompleteTag;
          PDF_OCR_TAGGING = "true";
          PDF_REPLACE = "false";
          PDF_SKIP_EXISTING_OCR = "false";
          PDF_UPLOAD = "false";
          TOKEN_LIMIT = "2000";
          VISION_LLM_MODEL = visionModel;
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
          "${stateDir}/config:/app/config:rw"
          "${stateDir}/db:/app/db:rw"
          "${stateDir}/hocr:/app/hocr:rw"
          "${stateDir}/home:/home/paperless-gpt:rw"
          "${stateDir}/pdf:/app/pdf:rw"
          "${stateDir}/prompts:/app/prompts:rw"
        ];
      };
    };
  };
}
