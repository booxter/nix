{ config, lib, ... }:
let
  enabledServices = lib.filterAttrs (_: service: service.enable) config.host.internalHttps.services;
  serviceServerNames =
    service: [ service.serverName ] ++ service.serverAliases ++ service.publicAliases;
  serverNames = builtins.concatMap serviceServerNames (builtins.attrValues enabledServices);
  probePortConflicts = lib.filterAttrs (
    _: service: service.probe.enable && service.probe.port == service.port
  ) enabledServices;
in
{
  assertions = lib.optionals (enabledServices != { }) [
    {
      assertion = builtins.length serverNames == builtins.length (lib.unique serverNames);
      message = "host.internalHttps.services must not reuse the same serverName, serverAlias, or publicAlias on one host.";
    }
    {
      assertion = probePortConflicts == { };
      message = "host.internalHttps.services probe listeners must use a port distinct from the normal service port. Offenders: ${lib.concatStringsSep ", " (builtins.attrNames probePortConflicts)}";
    }
  ];
}
