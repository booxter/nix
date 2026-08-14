{
  cfg,
  dashboardCatalog,
  lib,
  searchProviders,
}:
let
  provider = searchProviders.${cfg.search.provider} or null;
  searchEndpoint = if provider == null then null else provider.endpoint;
  resolve =
    name: instance:
    let
      entries = dashboardCatalog.${name};
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
  resolved = lib.mapAttrs resolve cfg.instances;
}
