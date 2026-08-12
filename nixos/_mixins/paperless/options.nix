{ lib, ... }:
{
  options.host.paperless = {
    enable = lib.mkEnableOption "Paperless document management";

    storage = {
      provider = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Host providing durable Paperless storage.";
      };
      resource = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "paperless";
        description = "Storage resource containing Paperless documents.";
      };
      mountPoint = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "/data/paperless";
        description = "Local mount point for durable Paperless storage.";
      };
    };

    sso.application = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "paperless";
      description = "SSO application defining Paperless users and administrators.";
    };

    gpt = {
      enable = lib.mkEnableOption "Paperless GPT enrichment";
      ollama.providerHost = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "NixOS host providing Ollama models to Paperless GPT.";
      };
      textModel = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Advertised Ollama model used for text classification.";
      };
      visionModel = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Advertised vision-capable Ollama model used for OCR.";
      };
    };
  };
}
