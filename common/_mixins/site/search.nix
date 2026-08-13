{
  config,
  lib,
  outputs,
  ...
}:
let
  endpointType = lib.types.submodule {
    options = {
      baseUrl = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Base URL of the search provider.";
      };

      searchPath = lib.mkOption {
        type = lib.types.strMatching "^/.*";
        default = "/search";
        description = "HTTP path accepting search queries.";
      };

      queryParameter = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "q";
        description = "Query-string parameter containing search terms.";
      };
    };
  };
  providerType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "the ${name} site search provider";

        title = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = lib.strings.toSentenceCase name;
          description = "Human-readable search provider title.";
        };

        aliases = lib.mkOption {
          type = with lib.types; listOf nonEmptyStr;
          default = [ ];
          description = "Optional browser keyword aliases for this provider.";
        };

        endpoints = {
          internal = lib.mkOption {
            type = with lib.types; nullOr endpointType;
            default = null;
            description = "Search endpoint reachable from the trusted site network.";
          };

          public = lib.mkOption {
            type = with lib.types; nullOr endpointType;
            default = null;
            description = "Search endpoint reachable outside the site network.";
          };
        };
      };
    }
  );
  model = import ./search-model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  enabled = lib.filterAttrs (_: provider: provider.enable) config.host.site.search.providers;
in
{
  options.host.site.search = {
    providers = lib.mkOption {
      type = lib.types.attrsOf providerType;
      default = { };
      description = "Search providers contributed by this host to its physical site.";
    };

    availableProviders = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = model.byId;
      readOnly = true;
      internal = true;
      description = "Search providers discovered across this host's physical site.";
    };
  };

  config.assertions = lib.mapAttrsToList (name: provider: {
    assertion = provider.endpoints.internal != null || provider.endpoints.public != null;
    message = "host.site.search.providers.${name} requires at least one endpoint";
  }) enabled;
}
