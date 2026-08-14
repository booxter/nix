{
  cfg,
  dashboardCatalog,
  lib,
  searchProviders,
}:
let
  enabled = lib.filterAttrs (_: instance: instance.enable) cfg.instances;
  resolve =
    name: instance:
    let
      provider = searchProviders.${instance.search.provider} or null;
      searchEndpoint = if provider == null then null else provider.endpoint;
      entries = dashboardCatalog.${instance.scope};
    in
    instance
    // {
      inherit
        entries
        name
        provider
        searchEndpoint
        ;
      sections = map (
        section:
        section
        // {
          entries = builtins.filter (entry: entry.section == section.id) entries;
        }
      ) instance.sections;
    };
in
{
  inherit enabled;
  resolved = lib.mapAttrs resolve enabled;
}
