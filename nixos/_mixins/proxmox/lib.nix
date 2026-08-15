{ lib }:
hosts:
let
  nodes = lib.filterAttrs (_: host: host.isNode) hosts;
  guests = lib.filterAttrs (_: host: host.isGuest) hosts;
in
lib.mapAttrs (
  _: guest:
  builtins.attrNames (
    lib.filterAttrs (_: node: node.realm == guest.realm && node.cluster == guest.cluster) nodes
  )
) guests
