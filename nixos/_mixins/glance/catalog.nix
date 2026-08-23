{
  fleetInventory,
  lib,
}:
let
  webEntries =
    map
      (
        contribution:
        let
          service = contribution.value;
          endpoint =
            exposure:
            if service.${exposure} == null then
              null
            else
              {
                url = service.${exposure}.url;
                checkUrl =
                  if service.health.frontend != null then
                    "${service.${exposure}.url}${service.health.frontend.path}"
                  else
                    null;
              };
        in
        {
          inherit (service.dashboard) icon id section;
          title = service.displayName;
          endpoints = {
            internal = endpoint "internal";
            public = if service.public == null then null else endpoint "public";
          };
        }
      )
      (
        builtins.filter (
          contribution: contribution.value.dashboard != null
        ) fleetInventory.webServices.contributions
      );
  directEntries = lib.mapAttrsToList (id: entry: {
    inherit id;
    inherit (entry)
      icon
      section
      title
      ;
    endpoints = {
      internal = {
        inherit (entry) url;
        checkUrl = entry.checkUrl or entry.url;
      };
      public = null;
    };
  }) fleetInventory.dashboard;
  entries = webEntries ++ directEntries;
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
{
  internal = forScope "internal";
  public = forScope "public";
}
