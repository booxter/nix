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
      message = "enabled host.glance.instances must use unique ports";
    }
  ]
  ++ builtins.concatLists (
    lib.mapAttrsToList (name: instance: [
      {
        assertion = instance.provider != null;
        message = "host.glance.instances.${name}.search.provider must name a site search provider";
      }
      {
        assertion = instance.searchEndpoint != null;
        message = "host.glance.instances.${name} requires a search endpoint compatible with its scope";
      }
      {
        assertion =
          builtins.length instance.sections
          == builtins.length (lib.unique (map (section: section.id) instance.sections));
        message = "host.glance.instances.${name}.sections must use unique IDs";
      }
    ]) model.resolved
  );
}
