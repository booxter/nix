{
  fleetInventory,
  lib,
  outputs,
}:
let
  contributions = fleetInventory.webServices.contributions;
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
  showContribution = contribution: "${contribution.owner}:${contribution.id}";
in
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
  inherit contributions;
  public = publicContributions;
  dashboard = builtins.filter (contribution: contribution.value.dashboard != null) contributions;
  frontendProbes = builtins.filter (
    contribution: contribution.value.health.frontend != null
  ) contributions;
  backendProbes = builtins.filter (
    contribution: contribution.value.health.backend != null
  ) contributions;
}
