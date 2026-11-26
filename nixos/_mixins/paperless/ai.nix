{
  config,
  lib,
  paperlessModel,
  ...
}:
let
  inherit (paperlessModel) cfg aiProvider ollamaTunnelPort;
  ollamaClient = config.host.pki.clients.paperless-ollama;
  ollamaServerName = aiProvider.host.web.services.ollama.internal.serverName;
  endpoint = "http://127.0.0.1:${toString ollamaTunnelPort}";
in
{
  config = lib.mkIf (cfg != null) {
    services.paperless = {
      settings = {
        PAPERLESS_AI_ENABLED = true;
        PAPERLESS_LLM_OCR_ENABLED = true;
        PAPERLESS_LLM_OCR_BASE_URL = "${endpoint}/v1";
        PAPERLESS_LLM_OCR_MODEL = cfg.ai.visionModel;
        PAPERLESS_AI_LLM_BACKEND = "ollama";
        PAPERLESS_AI_LLM_ENDPOINT = endpoint;
        PAPERLESS_AI_LLM_MODEL = cfg.ai.textModel;
        PAPERLESS_AI_LLM_OUTPUT_LANGUAGE = "English";
      };
    };

    host.pki.clients.paperless-ollama = {
      category = "internal";
      # Keep the identity of the issued client certificate.
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
      paperless-task-queue = {
        wants = [ "stunnel.service" ];
        after = [ "stunnel.service" ];
      };
    };
  };
}
