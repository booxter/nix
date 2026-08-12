{ pkgs, ... }:
let
  inherit (pkgs) lib;
  endpoint = url: {
    inherit url;
    checkUrl = null;
  };
  dashboard = import ../../nixos/_mixins/dashboard/model.nix {
    inherit lib;
    webEntries = [
      {
        id = "reader";
        owner = "apps-node";
        title = "Reader";
        icon = "sh:reader";
        section = "apps";
        endpoints = {
          internal = endpoint "https://reader.example.test";
          public = endpoint "https://reader.public.example.test";
        };
      }
    ];
    directEntries = [
      {
        id = "trust-bundle";
        owner = "authority-node";
        title = "Trust Bundle";
        icon = "sh:certificate";
        section = "infrastructure";
        endpoints = {
          internal = endpoint "https://authority.example.test/roots.pem";
          public = null;
        };
      }
    ];
  };
  localConfig = {
    host.site = {
      name = "test-site";
      search.providers = { };
    };
  };
  provider = {
    enable = true;
    title = "Private Search";
    aliases = [ "@private" ];
    endpoints = {
      internal = null;
      public = {
        baseUrl = "https://search.example.test";
        searchPath = "/search";
        queryParameter = "q";
      };
    };
  };
  search = import ../../common/_mixins/site/search-model.nix {
    config = localConfig;
    hostSpec.name = "desktop-node";
    inherit lib;
    outputs = {
      darwinConfigurations = { };
      nixosConfigurations.search-node.config.host.site = {
        name = "test-site";
        search.providers.private = provider;
      };
    };
  };
in
assert builtins.length dashboard.internal == 2;
assert builtins.length dashboard.public == 1;
assert (builtins.head dashboard.internal).endpoint.url == "https://reader.public.example.test";
assert dashboard.byId.trust-bundle.owner == "authority-node";
assert search.byId.private.owner == "search-node";
assert search.byId.private.endpoints.public.queryParameter == "q";
pkgs.runCommand "service-catalog-model-tests" { } ''
  touch "$out"
''
