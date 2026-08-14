{ config, lib }:
let
  services = config.host.web.services;
  internalServices = lib.filterAttrs (_: service: service.internal != null) services;
  normalize =
    serviceName: service:
    let
      internal = service.internal;
      localAliases = internal.localAliases ++ map (alias: "${alias}.local") internal.localAliases;
      serverAliases = localAliases ++ internal.aliases;
      publicAliases =
        internal.publicAliases
        ++ lib.optional (service.public != null && service.public.serveOnOwner) service.public.hostName;
    in
    service
    // {
      inherit serviceName;
      internal = internal // {
        inherit publicAliases serverAliases;
        sans = lib.unique (
          [
            internal.endpointName
            internal.serverName
          ]
          ++ serverAliases
          ++ publicAliases
        );
      };
    };
  normalizedInternalServices = lib.mapAttrs normalize internalServices;
  internalEndpoints = lib.mapAttrs' (
    _: service: lib.nameValuePair service.internal.endpointName service
  ) normalizedInternalServices;
in
{
  inherit
    internalEndpoints
    normalizedInternalServices
    services
    ;
  internalEndpointNames = map (service: service.internal.endpointName) (
    builtins.attrValues normalizedInternalServices
  );
  localAliases = lib.unique (
    builtins.concatMap (service: service.internal.localAliases) (
      builtins.attrValues normalizedInternalServices
    )
  );
}
