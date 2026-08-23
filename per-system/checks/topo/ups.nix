{
  fleetInventory,
  lib,
}:
let
  inherit (fleetInventory) hosts ups;
  serverNames = builtins.attrNames ups.servers;
  clientNames = builtins.attrNames ups.clients;
  invalidServerHosts = builtins.filter (
    name: !builtins.hasAttr name hosts || hosts.${name}.platform != "nixos"
  ) serverNames;
  invalidClientHosts = builtins.filter (name: !builtins.hasAttr name hosts) clientNames;
  unknownClientServers = builtins.filter (
    name: !builtins.hasAttr ups.clients.${name} ups.servers
  ) clientNames;
  serverClients = builtins.filter (name: builtins.hasAttr name ups.clients) serverNames;
  realmMismatches = builtins.filter (
    name:
    builtins.hasAttr name hosts
    && builtins.hasAttr ups.clients.${name} hosts
    && hosts.${name}.realm != hosts.${ups.clients.${name}}.realm
  ) clientNames;
in
lib.optional (invalidServerHosts != [ ]) (
  "UPS servers must name managed NixOS hosts: ${lib.concatStringsSep ", " invalidServerHosts}"
)
++ lib.optional (invalidClientHosts != [ ]) (
  "UPS clients must name managed hosts: ${lib.concatStringsSep ", " invalidClientHosts}"
)
++ lib.optional (unknownClientServers != [ ]) (
  "UPS clients reference unknown servers: ${lib.concatStringsSep ", " unknownClientServers}"
)
++ lib.optional (serverClients != [ ]) (
  "hosts cannot be both UPS servers and clients: ${lib.concatStringsSep ", " serverClients}"
)
++ lib.optional (realmMismatches != [ ]) (
  "UPS clients and servers must share a realm: ${lib.concatStringsSep ", " realmMismatches}"
)
