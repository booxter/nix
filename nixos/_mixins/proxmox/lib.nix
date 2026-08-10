{ lib }:
{
  build =
    hosts:
    let
      nodes = lib.filterAttrs (_: host: host.nodeCluster != null) hosts;
      guests = lib.filterAttrs (_: host: host.guestCluster != null) hosts;
      nodesByCluster = lib.foldl' (
        result: name:
        let
          cluster = nodes.${name}.nodeCluster;
        in
        result
        // {
          ${cluster} = (result.${cluster} or [ ]) ++ [ name ];
        }
      ) { } (builtins.attrNames nodes);
    in
    {
      inherit
        guests
        hosts
        nodes
        nodesByCluster
        ;

      guestNodes = lib.mapAttrs (_: guest: nodesByCluster.${guest.guestCluster} or [ ]) guests;
    };
}
