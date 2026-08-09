{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ localHost ];
  servicesByHost =
    lib.mapAttrs (
      _: configuration:
      lib.filterAttrs (_: service: service.enable) configuration.config.host.web.services
    ) otherConfigurations
    // {
      ${localHost} = lib.filterAttrs (_: service: service.enable) config.host.web.services;
    };
  contributions = builtins.concatLists (
    lib.mapAttrsToList (
      hostName: services:
      lib.mapAttrsToList (serviceName: service: {
        id = serviceName;
        owner = hostName;
        value = service;
      }) services
    ) servicesByHost
  );
  contributionsById = builtins.groupBy (contribution: contribution.id) contributions;
  duplicateIds = lib.filterAttrs (_: entries: builtins.length entries != 1) contributionsById;
  publicContributions = builtins.filter (
    contribution: contribution.value.public.enable
  ) contributions;
  contributionsByPublicHost = builtins.groupBy (
    contribution: contribution.value.public.hostName
  ) publicContributions;
  duplicatePublicHosts = lib.filterAttrs (
    _: entries: builtins.length entries != 1
  ) contributionsByPublicHost;
  unknownIngressServices = builtins.filter (
    contribution: !builtins.hasAttr contribution.value.public.ingressHost outputs.nixosConfigurations
  ) publicContributions;
  byId = lib.mapAttrs (
    _: entries:
    let
      contribution = builtins.head entries;
    in
    contribution.value
    // {
      inherit (contribution) id owner;
    }
  ) contributionsById;
  metrics = builtins.concatLists (
    map (
      contribution:
      lib.mapAttrsToList (metricName: metric: {
        inherit metricName;
        serviceId = contribution.id;
        owner = contribution.owner;
        value = metric;
      }) (lib.filterAttrs (_: metric: metric.enable) contribution.value.metrics)
    ) contributions
  );
  showContribution = contribution: "${contribution.owner}:${contribution.id}";
in
assert lib.assertMsg (duplicateIds == { }) (
  "web service IDs must be unique across the fleet: "
  + lib.concatStringsSep ", " (builtins.attrNames duplicateIds)
);
assert lib.assertMsg (duplicatePublicHosts == { }) (
  "public web service hostnames must be unique across the fleet: "
  + lib.concatStringsSep ", " (builtins.attrNames duplicatePublicHosts)
);
assert lib.assertMsg (unknownIngressServices == [ ]) (
  "web services reference unknown public ingress hosts: "
  + lib.concatStringsSep ", " (map showContribution unknownIngressServices)
);
{
  inherit
    byId
    contributions
    metrics
    servicesByHost
    ;
  public = publicContributions;
  dashboard = builtins.filter (
    contribution: contribution.value.presentation.dashboard.enable
  ) contributions;
  frontendProbes = builtins.filter (
    contribution: contribution.value.health.frontend.enable
  ) contributions;
  backendProbes = builtins.filter (
    contribution: contribution.value.health.backend.enable
  ) contributions;
}
