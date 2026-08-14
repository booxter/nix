{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model)
    cfg
    gptPort
    gptProvider
    gptStateDir
    ollamaTunnelPort
    paperlessService
    ;
  packages = import ./packages.nix { inherit pkgs; };
  containerImage = import ../../_lib/oci-image.nix {
    image = cfg.gpt.container;
    inherit pkgs;
  };
  inherit (containerImage) imageFile;
  image = containerImage.ref;
  containerUid = "10001";
  containerGid = "10001";
  autoTag = "paperless-gpt-auto";
  autoOcrTag = "paperless-gpt-ocr-auto";
  ocrCompleteTag = "paperless-gpt-ocr-complete";
  ollamaClient = config.host.pki.clients.paperless-ollama;
  ollamaServerName = gptProvider.host.web.services.ollama.internal.serverName;
in
{
  config = lib.mkIf (cfg.enable && cfg.gpt.enable) {
    host.pki.clients.paperless-ollama = {
      enable = true;
      category = "internal";
      commonName = "paperless-gpt.${config.networking.hostName}";
      materializations.default.restartUnits = [ "stunnel.service" ];
    };

    services.stunnel = {
      enable = true;
      logLevel = lib.mkDefault "warning";
      user = null;
      group = null;
      clients.paperless-ollama = {
        accept = "127.0.0.1:${toString ollamaTunnelPort}";
        connect = "${ollamaServerName}:443";
        cert = ollamaClient.materializations.default.certificatePath;
        key = ollamaClient.materializations.default.keyPath;
        checkHost = ollamaServerName;
        sni = ollamaServerName;
        CAFile = "${config.host.pki.authority.rootCaCertificate}";
        verifyChain = true;
        OCSPaia = false;
      };
    };

    systemd.services = {
      stunnel = {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
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
          ExecStart = lib.getExe packages.gptConfigure;
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
        unitConfig.RequiresMountsFor = [ gptStateDir ];
      };
    };

    systemd.tmpfiles.rules = [
      "d '${gptStateDir}' 0750 root root - -"
      "d '${gptStateDir}/config' 0750 ${containerUid} ${containerGid} - -"
      "d '${gptStateDir}/db' 0750 ${containerUid} ${containerGid} - -"
      "d '${gptStateDir}/hocr' 0750 ${containerUid} ${containerGid} - -"
      "d '${gptStateDir}/home' 0750 ${containerUid} ${containerGid} - -"
      "d '${gptStateDir}/pdf' 0750 ${containerUid} ${containerGid} - -"
      "d '${gptStateDir}/prompts' 0750 ${containerUid} ${containerGid} - -"
    ];

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
          LLM_LANGUAGE = "English";
          LLM_MODEL = cfg.gpt.textModel;
          LLM_PROVIDER = "ollama";
          LISTEN_INTERFACE = "127.0.0.1:${toString gptPort}";
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
          PAPERLESS_PUBLIC_URL = paperlessService.public.url;
          PDF_COPY_METADATA = "true";
          PDF_OCR_COMPLETE_TAG = ocrCompleteTag;
          PDF_OCR_TAGGING = "true";
          PDF_REPLACE = "false";
          PDF_SKIP_EXISTING_OCR = "false";
          PDF_UPLOAD = "false";
          TOKEN_LIMIT = "2000";
          VISION_LLM_MODEL = cfg.gpt.visionModel;
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
          "${gptStateDir}/config:/app/config:rw"
          "${gptStateDir}/db:/app/db:rw"
          "${gptStateDir}/hocr:/app/hocr:rw"
          "${gptStateDir}/home:/home/paperless-gpt:rw"
          "${gptStateDir}/pdf:/app/pdf:rw"
          "${gptStateDir}/prompts:/app/prompts:rw"
        ];
      };
    };
  };
}
