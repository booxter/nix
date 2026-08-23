{
  fleetInventory,
  lib,
}:
let
  inherit (fleetInventory) hosts observability wireguard;
  catalog = import ../../../lib/observability/catalog.nix {
    inherit fleetInventory lib;
  };
  realmServers = lib.mapAttrsToList (realm: entry: {
    inherit realm;
    host = entry.prometheusServer;
  }) observability.realms;
  invalidServers = builtins.filter (
    entry:
    !builtins.hasAttr entry.host hosts
    || hosts.${entry.host}.platform != "nixos"
    || hosts.${entry.host}.realm != entry.realm
  ) realmServers;
  observedHostNames = builtins.attrNames catalog.nodes;
  invalidBlackboxSources = builtins.filter (
    name: !builtins.elem name observedHostNames || hosts.${name}.platform != "nixos"
  ) observability.blackboxSources;
  unknownDashboardOverrides = builtins.filter (name: !builtins.hasAttr name hosts) (
    builtins.attrNames observability.dashboardOverrides
  );
  endpointOwners = builtins.attrNames observability.endpoints;
  wireguardNetworkNames = map (server: server.network) (builtins.attrValues wireguard.servers);
  invalidEndpointOwners = builtins.filter (
    name: !builtins.elem name observedHostNames || hosts.${name}.platform != "nixos"
  ) endpointOwners;
  unknownWireguardNetworks = builtins.concatMap (
    owner:
    lib.mapAttrsToList (_: endpoint: endpoint.wireguardNetwork) (
      lib.filterAttrs (
        _: endpoint:
        endpoint ? wireguardNetwork && !builtins.elem endpoint.wireguardNetwork wireguardNetworkNames
      ) observability.endpoints.${owner}
    )
  ) endpointOwners;
  duplicatePortHosts = builtins.filter (
    owner:
    let
      ports = map (endpoint: endpoint.port) (builtins.attrValues observability.endpoints.${owner});
    in
    builtins.length ports != builtins.length (lib.unique ports)
  ) endpointOwners;
  endpointsByJob = builtins.groupBy (endpoint: endpoint.jobName) catalog.endpoints;
  scrapeShape = endpoint: {
    inherit (endpoint)
      interval
      metricRelabelConfigs
      path
      ;
  };
  incompatibleJobs = builtins.attrNames (
    lib.filterAttrs (
      _: endpoints: builtins.length (lib.unique (map scrapeShape endpoints)) != 1
    ) endpointsByJob
  );
  nonMtlsRemoteNodes = lib.mapAttrsToList (name: _: name) (
    lib.filterAttrs (
      name: node: name != observability.realms.${hosts.${name}.realm}.prometheusServer && !node.mtls
    ) catalog.nodes
  );
in
lib.optional (invalidServers != [ ]) (
  "observability realms reference invalid Prometheus servers: "
  + lib.concatStringsSep ", " (map (entry: "${entry.realm}:${entry.host}") invalidServers)
)
++ lib.optional (invalidBlackboxSources != [ ]) (
  "remote blackbox sources must be observed NixOS hosts: "
  + lib.concatStringsSep ", " invalidBlackboxSources
)
++ lib.optional (unknownDashboardOverrides != [ ]) (
  "observability dashboard overrides reference unknown hosts: "
  + lib.concatStringsSep ", " unknownDashboardOverrides
)
++ lib.optional (invalidEndpointOwners != [ ]) (
  "observability endpoints must belong to observed NixOS hosts: "
  + lib.concatStringsSep ", " invalidEndpointOwners
)
++ lib.optional (unknownWireguardNetworks != [ ]) (
  "observability endpoints reference unknown WireGuard networks: "
  + lib.concatStringsSep ", " unknownWireguardNetworks
)
++ lib.optional (duplicatePortHosts != [ ]) (
  "observability endpoints reuse ports on hosts: " + lib.concatStringsSep ", " duplicatePortHosts
)
++ lib.optional (incompatibleJobs != [ ]) (
  "Prometheus endpoints sharing a job have incompatible scrape settings: "
  + lib.concatStringsSep ", " incompatibleJobs
)
++ lib.optional (nonMtlsRemoteNodes != [ ]) (
  "remote Prometheus node targets do not use mTLS: " + lib.concatStringsSep ", " nonMtlsRemoteNodes
)
