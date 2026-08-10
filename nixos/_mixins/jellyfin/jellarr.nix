{
  config,
  lib,
  outputs,
  ...
}:
let
  openAttrs = lib.types.attrsOf lib.types.anything;
  declarativeConfigModule = {
    freeformType = openAttrs;
    options = {
      system = lib.mkOption {
        type = lib.types.submodule {
          freeformType = openAttrs;
          options.pluginRepositories = lib.mkOption {
            type = lib.types.listOf openAttrs;
            default = [ ];
          };
        };
        default = { };
      };
      library.virtualFolders = lib.mkOption {
        type = lib.types.listOf openAttrs;
        default = [ ];
      };
      users = lib.mkOption {
        type = lib.types.listOf openAttrs;
        default = [ ];
      };
      plugins = lib.mkOption {
        type = lib.types.listOf openAttrs;
        default = [ ];
      };
    };
  };
  contributionModule = {
    options = {
      targetHost = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "NixOS host whose Jellyfin configuration receives this contribution.";
      };
      config = lib.mkOption {
        type = lib.types.submodule declarativeConfigModule;
        default = { };
        description = "Declarative Jellyfin configuration contributed to the target host.";
      };
    };
  };
  model = import ./model.nix { inherit config outputs; };
in
{
  options.host.jellyfin = {
    declarativeConfig = lib.mkOption {
      type = lib.types.submodule declarativeConfigModule;
      default = { };
      description = "Jellarr policy contributed by the Jellyfin host and its integrations.";
    };

    declarativeConfigContributions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule contributionModule);
      default = { };
      internal = true;
      description = "Declarative Jellyfin configuration addressed to fleet Jellyfin hosts.";
    };
  };

  config.host.jellyfin.declarativeConfig = lib.mkMerge (
    map (contribution: contribution.config) model.targetedContributions
  );
}
