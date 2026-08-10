{ lib }:
{
  build =
    hosts:
    let
      nodes = lib.filterAttrs (_: host: host.nodeCluster != null) hosts;
      guests = lib.filterAttrs (_: host: host.guestCluster != null) hosts;
      nodesByRealmCluster = lib.foldl' (
        result: name:
        let
          cluster = nodes.${name}.nodeCluster;
          realm = nodes.${name}.realm;
          realmClusters = result.${realm} or { };
        in
        result
        // {
          ${realm} = realmClusters // {
            ${cluster} = (realmClusters.${cluster} or [ ]) ++ [ name ];
          };
        }
      ) { } (builtins.attrNames nodes);
    in
    {
      inherit
        guests
        hosts
        nodes
        nodesByRealmCluster
        ;

      guestNodes = lib.mapAttrs (
        _: guest: nodesByRealmCluster.${guest.realm}.${guest.guestCluster} or [ ]
      ) guests;
    };
}
