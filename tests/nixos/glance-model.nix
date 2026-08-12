{ pkgs, ... }:
let
  inherit (pkgs) lib;
  endpoint = baseUrl: {
    inherit baseUrl;
    searchPath = "/find";
    queryParameter = "query";
  };
  entry = id: section: {
    inherit id section;
    owner = "catalog-node";
    title = id;
    icon = "sh:${id}";
    endpoints = { };
    endpoint = {
      url = "https://${id}.example.test";
      checkUrl = null;
    };
  };
  cfg.instances = {
    internal = {
      enable = true;
      port = 18080;
      scope = "internal";
      search.provider = "private";
      sections = [
        {
          id = "apps";
          title = "Applications";
        }
      ];
    };
    public = {
      enable = true;
      port = 18081;
      scope = "public";
      search.provider = "private";
      sections = [
        {
          id = "apps";
          title = "Applications";
        }
      ];
    };
    disabled.enable = false;
  };
  model = import ../../nixos/_mixins/glance/model.nix {
    inherit cfg lib;
    dashboardCatalog = {
      internal = [
        (entry "reader" "apps")
        (entry "authority" "infrastructure")
      ];
      public = [ (entry "reader" "apps") ];
    };
    searchProviders.private = {
      endpoints = {
        internal = endpoint "https://search.internal.example.test";
        public = endpoint "https://search.public.example.test";
      };
    };
  };
in
assert
  builtins.attrNames model.resolved == [
    "internal"
    "public"
  ];
assert model.resolved.internal.searchEndpoint.baseUrl == "https://search.public.example.test";
assert map (item: item.id) (builtins.head model.resolved.internal.sections).entries == [ "reader" ];
assert map (item: item.id) model.resolved.public.entries == [ "reader" ];
pkgs.runCommand "glance-model-test" { } ''
  touch "$out"
''
