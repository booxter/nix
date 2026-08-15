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

        endpoint = lib.mkOption {
          type = endpointType;
          description = "Search endpoint exposed by this provider.";
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
in
{
  options.host.site.search = {
    providers = lib.mkOption {
      type = lib.types.attrsOf providerType;
      default = { };
      description = "Search providers contributed by this host to its physical site.";
    };

    availableProviders = lib.mkOption {
      type = lib.types.attrsOf providerType;
      default = model.byId;
      readOnly = true;
      internal = true;
      description = "Search providers discovered across this host's physical site.";
    };
  };

}
