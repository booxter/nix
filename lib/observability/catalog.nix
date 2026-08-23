{
  fleetInventory,
  lib,
}:
let
  inherit (fleetInventory)
    builders
    hosts
    observability
    proxmox
    webServices
    wireguard
    ;
  wireguardNetworks = import ../../common/_mixins/wireguard/model.nix {
    inventory = wireguard;
    inherit lib;
  };
  observedHosts = lib.filterAttrs (_: host: builtins.hasAttr host.realm observability.realms) hosts;
  serverFor = host: observability.realms.${host.realm}.prometheusServer;
  isHypervisor = name: builtins.hasAttr name proxmox.nodes;
  isVirtual = name: builtins.hasAttr name proxmox.guests;
  overrideFor = name: observability.dashboardOverrides.${name} or { };
  nodeFor =
    name: host:
    let
      override = overrideFor name;
      hypervisor = isHypervisor name;
      virtual = isVirtual name;
      laptop = override.laptop or false;
    in
    {
      target = "${name}:9100";
      mtls = name != serverFor host;
      labels = {
        availability = if laptop then "intermittent" else "always";
        component = "node";
        host_builder = lib.boolToString (builtins.hasAttr name builders);
        host_hypervisor = lib.boolToString hypervisor;
        host_laptop = lib.boolToString laptop;
        host_network_source = if hypervisor then "classified" else "node";
        host_class = if virtual then "virtual" else "hardware";
        instance = name;
        inherit (host) realm;
        scrape_profile = "node";
      };
    };
  nodes = lib.mapAttrs nodeFor observedHosts;
  dashboardFor =
    name: host:
    let
      override = overrideFor name;
    in
    {
      inherit name;
      platform = if host.platform == "darwin" then "darwin" else "linux";
      virtual = isVirtual name;
      builder = builtins.hasAttr name builders;
      hypervisor = isHypervisor name;
      gpuVendor = override.gpuVendor or null;
      services = builtins.attrNames (webServices.byOwner.${name} or { });
      diskBays = override.diskBays or null;
      backupServer = override.backupServer or false;
    };
  dashboards = lib.mapAttrs dashboardFor observedHosts;
  wireguardMetricRelabels =
    networkName:
    lib.concatMap
      (peer: [
        {
          source_labels = [ "public_key" ];
          target_label = "peer";
          regex = lib.escapeRegex peer.publicKey;
          replacement = peer.name;
        }
        {
          source_labels = [ "public_key" ];
          target_label = "peer_address";
          regex = lib.escapeRegex peer.publicKey;
          replacement = peer.address;
        }
      ])
      (
        lib.mapAttrsToList (name: peer: {
          inherit name;
          inherit (peer) address publicKey;
        }) wireguardNetworks.${networkName}.peers
      );
  endpointFor = owner: name: endpoint: {
    inherit owner name;
    inherit (endpoint)
      component
      jobName
      path
      port
      profile
      ;
    interval = endpoint.interval or null;
    metricRelabelConfigs =
      if endpoint ? wireguardNetwork then
        wireguardMetricRelabels endpoint.wireguardNetwork
      else
        endpoint.metricRelabelConfigs or [ ];
    target = "${owner}:${toString endpoint.port}";
    labels = {
      availability = endpoint.availability or "always";
      inherit (endpoint) component;
      instance = owner;
      realm = hosts.${owner}.realm;
      scrape_profile = endpoint.profile;
    }
    // lib.optionalAttrs (endpoint ? service) {
      inherit (endpoint) service;
    }
    // (endpoint.labels or { });
  };
  literalEndpoints = builtins.concatMap (
    owner: lib.mapAttrsToList (endpointFor owner) observability.endpoints.${owner}
  ) (builtins.attrNames observability.endpoints);
  webEndpoints = builtins.concatMap (
    contribution:
    lib.mapAttrsToList (
      _name: metric:
      endpointFor contribution.owner metric.endpointName {
        inherit (metric)
          interval
          jobName
          labels
          path
          port
          ;
        component = contribution.id;
        profile = "application";
        service = contribution.id;
        availability = contribution.value.observability.availability;
      }
    ) (lib.filterAttrs (_: metric: metric.discover) contribution.value.metrics)
  ) webServices.contributions;
  endpoints = literalEndpoints ++ webEndpoints;
  proxmoxNodes = lib.filterAttrs (name: _: builtins.hasAttr name observedHosts) proxmox.nodes;
  proxmoxExporterFor =
    name: cluster:
    let
      contribution = builtins.head (
        builtins.filter (
          entry: entry.owner == name && entry.id == "proxmox-${name}"
        ) webServices.contributions
      );
      metric = builtins.head (builtins.attrValues contribution.value.metrics);
    in
    {
      inherit cluster;
      realm = hosts.${name}.realm;
      target = "${name}:${toString metric.port}";
      node = name;
      pveTarget = contribution.value.internal.serverName;
    };
  proxmoxExporters = lib.mapAttrsToList proxmoxExporterFor proxmoxNodes;
  blackboxSources = map (name: {
    host = name;
    exporter = "${name}:9115";
    scheme = "https";
    source = name;
  }) observability.blackboxSources;
in
{
  inherit
    blackboxSources
    dashboards
    endpoints
    nodes
    proxmoxExporters
    ;
}
