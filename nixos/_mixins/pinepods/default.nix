{
  config,
  lib,
  outputs,
  pkgs,
  storageModel,
  ...
}:
{
  imports = [
    ./ai.nix
    ./ai-settings.nix
    ./assertions.nix
    ./auth.nix
    ./bootstrap.nix
    ./cache.nix
    ./container.nix
    ./database.nix
    ./storage.nix
    ./subscriptions.nix
    ./web.nix
  ];

  options.host.pinepods = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          ollamaHost = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Host serving the ad-detection model through Ollama.";
          };
          adDetectionModel = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = "Ollama model used to identify advertisements.";
          };
        };
      }
    );
    default = null;
    description = "PinePods podcast server configuration.";
  };

  config._module.args.pinepodsModel = import ./model.nix {
    inherit
      config
      outputs
      pkgs
      storageModel
      ;
  };
}
