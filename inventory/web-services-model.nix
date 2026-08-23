{
  entriesByOwner,
  hosts,
  lib,
  webIngress,
}:
let
  entries = builtins.concatLists (
    lib.mapAttrsToList (
      owner: ownerEntries:
      lib.mapAttrsToList (
        id: entry:
        entry
        // {
          inherit id owner;
        }
      ) ownerEntries
    ) entriesByOwner
  );
  normalizeRoute = _name: route: {
    inherit (route) location;
    upstream = route.upstream or null;
    proxyWebsockets = route.proxyWebsockets or false;
    bandwidthLimit = route.bandwidthLimit or null;
  };
  normalize =
    entry:
    let
      inherit (entry) id owner;
      service = entry.declaration;
      publicDeclaration = service.public or null;
      internalDeclaration = service.internal or { };
      health = service.health or { };
      observability = service.observability or { };
      ingress = webIngress.${hosts.${owner}.realm} or null;
      ingressHost = if ingress == null then null else ingress.host;
      public =
        if publicDeclaration == null then
          null
        else
          {
            inherit ingressHost;
            hostName = publicDeclaration.hostName;
            splitDnsHost = publicDeclaration.splitDnsHost or ingressHost;
            url = "https://${publicDeclaration.hostName}";
            locationExtraConfig = publicDeclaration.locationExtraConfig or "";
            routes = lib.mapAttrs normalizeRoute (publicDeclaration.routes or { });
          };
      internal =
        if internalDeclaration == null then
          null
        else
          let
            serverName = internalDeclaration.serverName or "${id}.home.arpa";
          in
          {
            inherit serverName;
            clientAuth = internalDeclaration.clientAuth or (if public == null then "none" else "mtls");
            url = "https://${serverName}";
          };
      normalizeProbe =
        probe: extra:
        {
          path = probe.path or "/";
          module = probe.module or "http_service";
        }
        // extra;
      normalizeMetric =
        metricName: metric:
        let
          defaultName = if metricName == "default" then id else "${id}-${metricName}";
        in
        {
          endpointName = metric.endpointName or defaultName;
          jobName = metric.jobName or defaultName;
          port = metric.port;
          path = metric.path or "/metrics";
          discover = metric.discover or true;
          interval = metric.scrapeInterval or null;
          labels = metric.labels or { };
        };
      dashboardDeclaration = service.dashboard or null;
    in
    {
      inherit id owner;
      value = {
        upstream = service.upstream or null;
        inherit internal public;
        displayName = service.displayName or (lib.strings.toSentenceCase id);
        health = {
          frontend = if (health.frontend or null) == null then null else normalizeProbe health.frontend { };
          backend =
            if (health.backend or null) == null then
              null
            else
              normalizeProbe health.backend {
                title = health.backend.title or "Backend HTTP";
              };
        };
        metrics = lib.mapAttrs normalizeMetric (service.metrics or { });
        observability = {
          availability = entry.availability or "always";
          importance = observability.importance or "normal";
          externalProbe.requirement = (observability.externalProbe or { }).requirement or "eligible";
        };
        dashboard =
          if dashboardDeclaration == null then
            null
          else
            {
              id = dashboardDeclaration.id or id;
              icon = dashboardDeclaration.icon or "sh:${id}";
              section = dashboardDeclaration.section;
            };
      };
    };
in
{
  byOwner = entriesByOwner;
  contributions = map normalize entries;
}
