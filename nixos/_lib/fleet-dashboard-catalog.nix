{
  config,
  fleetWebServices,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ localHost ];
  hostConfigs = lib.mapAttrs (_: configuration: configuration.config) otherConfigurations // {
    ${localHost} = config;
  };
  webEntries = map (
    contribution:
    let
      service = contribution.value;
      endpoint = exposure: {
        url = service.${exposure}.url;
        checkUrl =
          if service.health.frontend != null then
            "${service.${exposure}.url}${service.health.frontend.path}"
          else
            null;
      };
    in
    {
      inherit (contribution) id;
      title = service.displayName;
      inherit (service.dashboard) icon section;
      endpoints = {
        internal = endpoint "internal";
        public = if service.public == null then null else endpoint "public";
      };
    }
  ) fleetWebServices.dashboard;
  directEntries = builtins.concatMap (
    hostConfig:
    lib.mapAttrsToList (id: entry: {
      inherit id;
      inherit (entry)
        icon
        section
        title
        ;
      endpoints = {
        internal = {
          inherit (entry) checkUrl url;
        };
        public = null;
      };
    }) hostConfig.host.dashboard.entries
  ) (builtins.attrValues hostConfigs);
  entries = webEntries ++ directEntries;
  byIdLists = builtins.groupBy (entry: entry.id) entries;
  duplicateIds = lib.filterAttrs (_: values: builtins.length values != 1) byIdLists;
  forScope =
    scope:
    map (
      entry:
      entry
      // {
        endpoint =
          if scope == "public" || entry.endpoints.public != null then
            entry.endpoints.public
          else
            entry.endpoints.internal;
      }
    ) (builtins.filter (entry: scope != "public" || entry.endpoints.public != null) entries);
in
assert lib.assertMsg (duplicateIds == { }) (
  "dashboard entry IDs must be unique across the fleet: "
  + lib.concatStringsSep ", " (builtins.attrNames duplicateIds)
);
{
  internal = forScope "internal";
  public = forScope "public";
}
