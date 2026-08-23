{ config, lib, ... }:
let
  cfg = config.host.nix.cacheWarmer;
  formatBuilder = import ../../../../common/_lib/format-nix-builder.nix { inherit lib; };
  buildMachines = map (
    builder:
    builder
    // {
      maxJobs = lib.attrByPath [ builder.hostName ] builder.maxJobs cfg.builderMaxJobs;
    }
  ) config.nix.buildMachines;
  builderString = lib.concatStringsSep " ; " (map formatBuilder buildMachines);
  unknownBuilders = lib.subtractLists (map (builder: builder.hostName) config.nix.buildMachines) (
    builtins.attrNames cfg.builderMaxJobs
  );
  enabled = cfg.fleet.enable || cfg.nixpkgs.enable;
in
{
  options.host.nix.cacheWarmer = {
    builderMaxJobs = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = { };
      description = "Per-builder maximum concurrent jobs for cache-warmer Nix invocations.";
    };

    builders = lib.mkOption {
      type = lib.types.str;
      default = builderString;
      readOnly = true;
      internal = true;
      description = "Complete cache-warmer Nix machines configuration.";
    };
  };

  config.assertions = lib.optional enabled {
    assertion = unknownBuilders == [ ];
    message = "unknown cache-warmer builders: ${lib.concatStringsSep ", " unknownBuilders}";
  };
}
