{ lib }:
{
  build =
    hosts:
    let
      nodes = lib.filterAttrs (_: host: host.isNode) hosts;
      controllers = lib.filterAttrs (_: host: host.isNode && host.controller) hosts;
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
      controllersByRealmCluster = lib.foldl' (
        result: name:
        let
          controller = controllers.${name};
          realmControllers = result.${controller.realm} or { };
        in
        result
        // {
          ${controller.realm} = realmControllers // {
            ${controller.cluster} = (realmControllers.${controller.cluster} or [ ]) ++ [ name ];
          };
        }
      ) { } (builtins.attrNames controllers);
    in
    {
      inherit
        guests
        hosts
        nodes
        nodesByRealmCluster
        controllers
        controllersByRealmCluster
        ;

      guestNodes = lib.mapAttrs (
        _: guest: nodesByRealmCluster.${guest.realm}.${guest.cluster} or [ ]
      ) guests;
    };
}
