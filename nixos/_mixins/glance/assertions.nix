{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.glance;
  model = import ./model.nix {
    inherit cfg lib;
    dashboardCatalog = import ../../_lib/fleet-dashboard-catalog.nix {
      inherit config lib outputs;
    };
    searchProviders = config.host.site.search.availableProviders;
  };
  instances = builtins.attrValues model.resolved;
in
{
  config.assertions = [
    {
      assertion =
        builtins.length instances == builtins.length (lib.unique (map (instance: instance.port) instances));
      message = "host.glance.instances must use unique ports";
    }
    {
      assertion = builtins.all (instance: instance.provider != null) instances;
      message = "host.glance.search.provider must name a site search provider";
    }
    {
      assertion = builtins.all (instance: instance.searchEndpoint != null) instances;
      message = "host.glance.search.provider must expose a search endpoint";
    }
  ]
  ++ builtins.concatLists (
    lib.mapAttrsToList (name: instance: [
      {
        assertion =
          builtins.length instance.sections
          == builtins.length (lib.unique (map (section: section.id) instance.sections));
        message = "host.glance.instances.${name}.sections must use unique IDs";
      }
    ]) model.resolved
  );
}
