{
  config,
  fleetInventory,
  lib,
  ...
}:
let
  localHost = config.networking.hostName;
  localSite = config.host.site.name;
  siteInventory = fleetInventory.sites.${localSite} or null;
  inventoryProviders = if siteInventory == null then { } else siteInventory.searchProviders;
  availableProviders = lib.mapAttrs (_: provider: removeAttrs provider [ "host" ]) inventoryProviders;
  expectedLocalProviders = lib.mapAttrs (_: provider: removeAttrs provider [ "host" ]) (
    lib.filterAttrs (_: provider: provider.host == localHost) inventoryProviders
  );
  providerEntries = builtins.concatLists (
    lib.mapAttrsToList (
      site: inventory:
      lib.mapAttrsToList (id: provider: {
        inherit id provider site;
      }) inventory.searchProviders
    ) fleetInventory.sites
  );
  invalidProviderEntries = builtins.filter (
    entry:
    !(builtins.hasAttr entry.provider.host fleetInventory.hosts)
    || fleetInventory.hosts.${entry.provider.host}.site != entry.site
  ) providerEntries;
  invalidProviderIds = map (entry: "${entry.site}.${entry.id}") invalidProviderEntries;
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
      default = availableProviders;
      readOnly = true;
      internal = true;
      description = "Search providers published for this host's physical site.";
    };
  };

  config.assertions = [
    {
      assertion = siteInventory != null;
      message = "site '${localSite}' must exist in fleet inventory";
    }
    {
      assertion = fleetInventory.hosts.${localHost}.site == localSite;
      message = "local site must match fleet host inventory";
    }
    {
      assertion = invalidProviderEntries == [ ];
      message = "search provider inventory entries must name hosts in their site: ${lib.concatStringsSep ", " invalidProviderIds}";
    }
    {
      assertion = config.host.site.search.providers == expectedLocalProviders;
      message = "local search provider publication must match fleet site inventory";
    }
  ];
}
