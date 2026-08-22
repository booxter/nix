{
  fleetInventory,
  lib,
}:
let
  inherit (fleetInventory) hosts proxmox ups;
  clusterNames = builtins.attrNames proxmox.clusters;
  guestNames = builtins.attrNames proxmox.guests;
  clusterNodeNames = builtins.concatMap (
    clusterName: proxmox.clusters.${clusterName}.nodes
  ) clusterNames;
  nodeNames = builtins.attrNames proxmox.nodes;
  duplicateNodes = builtins.filter (
    name: builtins.length (builtins.filter (candidate: candidate == name) clusterNodeNames) > 1
  ) (lib.unique clusterNodeNames);
  invalidNodes = builtins.filter (
    name: !builtins.hasAttr name hosts || hosts.${name}.platform != "nixos"
  ) nodeNames;
  invalidGuests = builtins.filter (
    name: !builtins.hasAttr name hosts || hosts.${name}.platform != "nixos"
  ) guestNames;
  unknownGuestClusters = builtins.filter (
    name: !builtins.hasAttr proxmox.guests.${name} proxmox.clusters
  ) guestNames;
  unknownNodeClusters = builtins.filter (
    name: !builtins.hasAttr proxmox.nodes.${name} proxmox.clusters
  ) nodeNames;
  missingNodeMappings = builtins.filter (name: !builtins.hasAttr name proxmox.nodes) clusterNodeNames;
  invalidNodeMappings = builtins.filter (
    name:
    builtins.hasAttr proxmox.nodes.${name} proxmox.clusters
    && !(builtins.elem name proxmox.clusters.${proxmox.nodes.${name}}.nodes)
  ) nodeNames;
  nodeGuests = builtins.filter (name: builtins.hasAttr name proxmox.nodes) guestNames;
  emptyClusters = builtins.filter (
    clusterName: proxmox.clusters.${clusterName}.nodes == [ ]
  ) clusterNames;
  invalidControllers = builtins.filter (
    clusterName:
    !(builtins.elem proxmox.clusters.${clusterName}.controller proxmox.clusters.${clusterName}.nodes)
  ) clusterNames;
  guestsForCluster =
    clusterName: builtins.filter (name: proxmox.guests.${name} == clusterName) guestNames;
  membersForCluster =
    clusterName: proxmox.clusters.${clusterName}.nodes ++ guestsForCluster clusterName;
  realmMismatches = builtins.filter (
    clusterName:
    builtins.length (lib.unique (map (name: hosts.${name}.realm) (membersForCluster clusterName))) != 1
  ) clusterNames;
  upsServerFor =
    name: if builtins.hasAttr name ups.servers then name else ups.clients.${name} or null;
  upsMismatches = builtins.filter (
    clusterName: builtins.length (lib.unique (map upsServerFor (membersForCluster clusterName))) != 1
  ) clusterNames;
in
lib.optional (duplicateNodes != [ ]) (
  "Proxmox nodes belong to multiple clusters: ${lib.concatStringsSep ", " duplicateNodes}"
)
++ lib.optional (invalidNodes != [ ]) (
  "Proxmox nodes must name managed NixOS hosts: ${lib.concatStringsSep ", " invalidNodes}"
)
++ lib.optional (invalidGuests != [ ]) (
  "Proxmox guests must name managed NixOS hosts: ${lib.concatStringsSep ", " invalidGuests}"
)
++ lib.optional (unknownGuestClusters != [ ]) (
  "Proxmox guests reference unknown clusters: ${lib.concatStringsSep ", " unknownGuestClusters}"
)
++ lib.optional (unknownNodeClusters != [ ]) (
  "Proxmox nodes reference unknown clusters: ${lib.concatStringsSep ", " unknownNodeClusters}"
)
++ lib.optional (missingNodeMappings != [ ]) (
  "Proxmox cluster nodes need direct mappings: ${lib.concatStringsSep ", " missingNodeMappings}"
)
++ lib.optional (invalidNodeMappings != [ ]) (
  "Proxmox node mappings must agree with cluster membership: ${lib.concatStringsSep ", " invalidNodeMappings}"
)
++ lib.optional (nodeGuests != [ ]) (
  "hosts cannot be both Proxmox nodes and guests: ${lib.concatStringsSep ", " nodeGuests}"
)
++ lib.optional (emptyClusters != [ ]) (
  "Proxmox clusters must contain nodes: ${lib.concatStringsSep ", " emptyClusters}"
)
++ lib.optional (invalidControllers != [ ]) (
  "Proxmox cluster controllers must be cluster nodes: ${lib.concatStringsSep ", " invalidControllers}"
)
++ lib.optional (realmMismatches != [ ]) (
  "Proxmox cluster members must share a realm: ${lib.concatStringsSep ", " realmMismatches}"
)
++ lib.optional (upsMismatches != [ ]) (
  "Proxmox cluster members must use one UPS server: ${lib.concatStringsSep ", " upsMismatches}"
)
