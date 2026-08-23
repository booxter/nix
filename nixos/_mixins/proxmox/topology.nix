{
  config,
  fleetInventory,
}:
let
  hostName = config.networking.hostName;
  nodeClusterName = fleetInventory.proxmox.nodes.${hostName} or null;
  guestClusterName = fleetInventory.proxmox.guests.${hostName} or null;
  clusterName = if guestClusterName != null then guestClusterName else nodeClusterName;
  cluster = if clusterName == null then null else fleetInventory.proxmox.clusters.${clusterName};
in
{
  inherit
    cluster
    clusterName
    guestClusterName
    nodeClusterName
    ;
  isController = cluster != null && cluster.controller == hostName;
  isGuest = guestClusterName != null;
  isNode = nodeClusterName != null;
  nodeNames = if cluster == null then [ ] else cluster.nodes;
}
