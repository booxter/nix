{ lib }:
{
  collect =
    publicServices:
    builtins.concatLists (
      map (
        contribution:
        lib.mapAttrsToList (
          routeName: route:
          route
          // {
            id = "${contribution.id}-${routeName}";
            inherit contribution routeName;
            upstream =
              if route.upstream != null then
                route.upstream
              else if contribution.value.public.transport == "direct" then
                contribution.value.public.directUpstream
              else
                contribution.value.internal.url;
          }
        ) (lib.filterAttrs (_: route: route.bandwidthLimit.enable) contribution.value.public.routes)
      ) publicServices
    );
}
