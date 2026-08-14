{ lib, ... }:
{
  options.host.paperless = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          storageProvider = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Host providing durable Paperless storage.";
          };

          gpt = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.submodule {
                options = {
                  providerHost = lib.mkOption {
                    type = lib.types.nonEmptyStr;
                    description = "NixOS host providing Ollama models to Paperless GPT.";
                  };
                  textModel = lib.mkOption {
                    type = lib.types.nonEmptyStr;
                    description = "Advertised Ollama model used for text classification.";
                  };
                  visionModel = lib.mkOption {
                    type = lib.types.nonEmptyStr;
                    description = "Advertised vision-capable Ollama model used for OCR.";
                  };
                };
              }
            );
            default = null;
            description = "Paperless GPT enrichment configuration.";
          };
        };
      }
    );
    default = null;
    description = "Paperless document management configuration.";
  };
}
