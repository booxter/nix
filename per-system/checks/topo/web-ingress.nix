{
  fleetInventory,
  lib,
}:
let
  inherit (fleetInventory) hosts webIngress;
  publicServices = builtins.filter (
    contribution: contribution.value.public != null
  ) fleetInventory.webServices.contributions;
  unknownHosts = lib.mapAttrsToList (realm: _ingress: realm) (
    lib.filterAttrs (_: ingress: !builtins.hasAttr ingress.host hosts) webIngress
  );
  realmMismatches = lib.mapAttrsToList (realm: _ingress: realm) (
    lib.filterAttrs (
      realm: ingress: builtins.hasAttr ingress.host hosts && hosts.${ingress.host}.realm != realm
    ) webIngress
  );
  missingServiceIngress = map (contribution: "${contribution.owner}:${contribution.id}") (
    builtins.filter (contribution: contribution.value.public.ingressHost == null) publicServices
  );
in
lib.optional (unknownHosts != [ ]) (
  "web ingress references unknown hosts for realms: " + lib.concatStringsSep ", " unknownHosts
)
++ lib.optional (realmMismatches != [ ]) (
  "web ingress hosts belong to the wrong realm: " + lib.concatStringsSep ", " realmMismatches
)
++ lib.optional (missingServiceIngress != [ ]) (
  "public web services have no realm ingress: " + lib.concatStringsSep ", " missingServiceIngress
)
