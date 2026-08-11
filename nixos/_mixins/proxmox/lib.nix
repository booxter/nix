{ lib }:
{
  build =
    hosts:
    let
      nodes = lib.filterAttrs (_: host: host.isNode) hosts;
      guests = lib.filterAttrs (_: host: host.isGuest) hosts;
      nodesByRealmCluster = lib.foldl' (
        result: name:
        let
          cluster = nodes.${name}.cluster;
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
        _: guest: nodesByRealmCluster.${guest.realm}.${guest.cluster} or [ ]
      ) guests;
    };
}
