{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
{
  imports = [
    ./assertions.nix
    ./bootstrap.nix
    ./ai.nix
    ./observability.nix
    ./secrets.nix
    ./service.nix
    ./sso.nix
    ./storage.nix
    ./web.nix
  ];

  options.host.paperless = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          storageProvider = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Host providing durable Paperless storage.";
          };

          ai = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.submodule {
                options = {
                  providerHost = lib.mkOption {
                    type = lib.types.nonEmptyStr;
                    description = "NixOS host providing Ollama models to Paperless.";
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
            description = "Local OCR and metadata suggestions for Paperless.";
          };
        };
      }
    );
    default = null;
    description = "Paperless document management configuration.";
  };

  config._module.args = {
    paperlessModel = import ./model.nix { inherit config lib outputs; };
    paperlessPackages = {
      bootstrap = pkgs.callPackage ./pkgs/paperless-bootstrap {
        paperless-ngx = config.services.paperless.package;
      };
      prometheusExporter = pkgs.callPackage ./pkgs/prometheus-paperless-exporter { };
    };
  };
}
