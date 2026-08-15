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
              else if contribution.value.internal != null then
                contribution.value.internal.url
              else
                contribution.value.upstream;
          }
        ) (lib.filterAttrs (_: route: route.bandwidthLimit != null) contribution.value.public.routes)
      ) publicServices
    );
}
