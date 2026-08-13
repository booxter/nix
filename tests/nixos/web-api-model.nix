{ pkgs, ... }:
let
  inherit (pkgs) lib;
  config.host.web = {
    api.catalog = {
      service = "catalog";
      interface = "catalog-v2";
      healthPath = "/ready";
      localUnit = "catalog.service";
      authentication.apiKey = {
        source = "/var/lib/catalog/config.xml";
        format = "xml-element";
        field = "ApiKey";
      };
    };
    services.catalog = {
      enable = true;
      internal.serverName = "catalog.example.test";
      health.backend.port = 9443;
    };
  };
  model = import ../../nixos/_mixins/web/api-model.nix { inherit config lib; };
in
assert model.resolved.catalog.interface == "catalog-v2";
assert model.resolved.catalog.url == "https://catalog.example.test:9443";
assert model.resolved.catalog.healthUrl == "https://catalog.example.test:9443/ready";
assert model.resolved.catalog.authentication.apiKey.field == "ApiKey";
pkgs.runCommand "web-api-model-test" { } ''
  touch "$out"
''
