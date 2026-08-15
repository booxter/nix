{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ localHost ];
  servicesByHost =
    lib.mapAttrs (_: configuration: configuration.config.host.web.services) otherConfigurations
    // {
      ${localHost} = config.host.web.services;
    };
  hostConfigs = lib.mapAttrs (_: configuration: configuration.config) otherConfigurations // {
    ${localHost} = config;
  };
  ingressControllersByRealm = builtins.groupBy (hostName: hostConfigs.${hostName}.host.realm) (
    builtins.attrNames (
      lib.filterAttrs (_: hostConfig: hostConfig.host.web.ingress != null) hostConfigs
    )
  );
  rawContributions = builtins.concatLists (
    lib.mapAttrsToList (
      hostName: services:
      lib.mapAttrsToList (serviceName: service: {
        id = serviceName;
        owner = hostName;
        value = service;
      }) services
    ) servicesByHost
  );
  resolvePublicContribution =
    contribution:
    if contribution.value.public == null then
      contribution
    else
      let
        ownerRealm = hostConfigs.${contribution.owner}.host.realm;
        realmControllers = ingressControllersByRealm.${ownerRealm} or [ ];
        ingressHost =
          if builtins.length realmControllers == 1 then builtins.head realmControllers else null;
        splitDnsHost =
          if contribution.value.public.splitDnsHost != null then
            contribution.value.public.splitDnsHost
          else
            ingressHost;
      in
      contribution
      // {
        value = contribution.value // {
          public = contribution.value.public // {
            inherit ingressHost splitDnsHost;
          };
        };
      };
  contributions = map resolvePublicContribution rawContributions;
  contributionsById = builtins.groupBy (contribution: contribution.id) contributions;
  duplicateIds = lib.filterAttrs (_: entries: builtins.length entries != 1) contributionsById;
  publicContributions = builtins.filter (
    contribution: contribution.value.public != null
  ) contributions;
  contributionsByPublicHost = builtins.groupBy (
    contribution: contribution.value.public.hostName
  ) publicContributions;
  duplicatePublicHosts = lib.filterAttrs (
    _: entries: builtins.length entries != 1
  ) contributionsByPublicHost;
  unknownIngressServices = builtins.filter (
    contribution:
    contribution.value.public.ingressHost == null
    || !builtins.hasAttr contribution.value.public.ingressHost outputs.nixosConfigurations
  ) publicContributions;
  unknownSplitDnsServices = builtins.filter (
    contribution:
    contribution.value.public.splitDnsHost == null
    || !builtins.hasAttr contribution.value.public.splitDnsHost outputs.nixosConfigurations
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
      }) contribution.value.metrics
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
  "web services require one realm ingress controller or an explicit known ingress host: "
  + lib.concatStringsSep ", " (map showContribution unknownIngressServices)
);
assert lib.assertMsg (unknownSplitDnsServices == [ ]) (
  "web services reference unknown split-DNS hosts: "
  + lib.concatStringsSep ", " (map showContribution unknownSplitDnsServices)
);
{
  inherit
    byId
    contributions
    metrics
    servicesByHost
    ;
  public = publicContributions;
  dashboard = builtins.filter (contribution: contribution.value.dashboard != null) contributions;
  frontendProbes = builtins.filter (
    contribution: contribution.value.health.frontend != null
  ) contributions;
  backendProbes = builtins.filter (
    contribution: contribution.value.health.backend != null
  ) contributions;
}
