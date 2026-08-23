{
  fleetInventory,
  lib,
}:
let
  inherit (fleetInventory) hosts;
  contributions = fleetInventory.webServices.contributions;
  contributionsById = builtins.groupBy (entry: entry.id) contributions;
  duplicateIds = builtins.attrNames (
    lib.filterAttrs (_: entries: builtins.length entries != 1) contributionsById
  );
  unknownOwners = builtins.filter (
    contribution: !builtins.hasAttr contribution.owner hosts
  ) contributions;
  publicContributions = builtins.filter (
    contribution: contribution.value.public != null
  ) contributions;
  contributionsByPublicHost = builtins.groupBy (
    contribution: contribution.value.public.hostName
  ) publicContributions;
  duplicatePublicHosts = builtins.attrNames (
    lib.filterAttrs (_: entries: builtins.length entries != 1) contributionsByPublicHost
  );
  unknownIngressServices = builtins.filter (
    contribution:
    contribution.value.public.ingressHost == null
    || !builtins.hasAttr contribution.value.public.ingressHost hosts
  ) publicContributions;
  unknownSplitDnsServices = builtins.filter (
    contribution:
    contribution.value.public.splitDnsHost == null
    || !builtins.hasAttr contribution.value.public.splitDnsHost hosts
  ) publicContributions;
  showContribution = contribution: "${contribution.owner}:${contribution.id}";
in
lib.optional (duplicateIds != [ ]) (
  "web service inventory IDs must be unique: " + lib.concatStringsSep ", " duplicateIds
)
++ lib.optional (unknownOwners != [ ]) (
  "web service inventory references unknown owners: "
  + lib.concatStringsSep ", " (map showContribution unknownOwners)
)
++ lib.optional (duplicatePublicHosts != [ ]) (
  "public web service hostnames must be unique: " + lib.concatStringsSep ", " duplicatePublicHosts
)
++ lib.optional (unknownIngressServices != [ ]) (
  "web services reference unknown ingress hosts: "
  + lib.concatStringsSep ", " (map showContribution unknownIngressServices)
)
++ lib.optional (unknownSplitDnsServices != [ ]) (
  "web services reference unknown split-DNS hosts: "
  + lib.concatStringsSep ", " (map showContribution unknownSplitDnsServices)
)
