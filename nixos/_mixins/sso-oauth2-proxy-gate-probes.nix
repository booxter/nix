{ lib }:
let
  # Internal service names that request exact backend probe locations. Example:
  # the Search gate has `probeLocationsByName.search."= /healthz"`.
  serviceNamesFor = gate: builtins.attrNames gate.probeLocationsByName;

  # Probe location sets must be non-empty so enabling a probe listener always
  # exposes at least one intentional backend check. Example offender:
  # `probeLocationsByName.search = { };`.
  emptyServiceNamesFor =
    gate:
    builtins.filter (serviceName: gate.probeLocationsByName.${serviceName} == { }) (
      serviceNamesFor gate
    );

  # Flatten probe location keys so assertions can reject broad auth bypasses.
  # Example: `search:= /healthz` is allowed; `search:/healthz` is not because
  # it would be a prefix location rather than one exact backend probe URL.
  locationEntriesFor =
    gate:
    builtins.concatMap (
      serviceName:
      map (locationName: {
        inherit locationName serviceName;
        label = "${serviceName}:${locationName}";
      }) (builtins.attrNames gate.probeLocationsByName.${serviceName})
    ) (serviceNamesFor gate);

  # Probe bypass locations must be exact nginx matches so we never accidentally
  # expose an unauthenticated subtree. Example offender: `search:/healthz`.
  unsafeLocationNamesFor =
    gate:
    map (entry: entry.label) (
      builtins.filter (entry: !(lib.hasPrefix "= /" entry.locationName)) (locationEntriesFor gate)
    );

  # Probe-only vhost name created by internal-https-service. Example: `search`
  # maps to `internal-https-search-probe`.
  vhostNameFor = serviceName: "internal-https-${serviceName}-probe";
in
{
  # Enable the probe listener only for services with explicit probe locations.
  # Example: a Search health URL turns on `host.internalHttps.services.search.probe`.
  enableAttrsFor =
    gate:
    lib.genAttrs (serviceNamesFor gate) (_: {
      probe.enable = true;
    });

  assertionsFor =
    gateName: gate:
    let
      unknownProbeServices = builtins.filter (
        serviceName: !(builtins.elem serviceName gate.internalHttpsServiceNames)
      ) (serviceNamesFor gate);
    in
    [
      {
        assertion = unknownProbeServices == [ ];
        message = "host.sso.oauth2ProxyGates.${gateName}.probeLocationsByName must only reference internalHttpsServiceNames.";
      }
      {
        assertion = unsafeLocationNamesFor gate == [ ];
        message = "host.sso.oauth2ProxyGates.${gateName}.probeLocationsByName must use exact nginx locations like '= /healthz'. Offenders: ${lib.concatStringsSep ", " (unsafeLocationNamesFor gate)}";
      }
      {
        assertion = emptyServiceNamesFor gate == [ ];
        message = "host.sso.oauth2ProxyGates.${gateName}.probeLocationsByName entries must not be empty. Offenders: ${lib.concatStringsSep ", " (emptyServiceNamesFor gate)}";
      }
    ];

  # Probe vhosts get only their explicit probe locations, not the normal app
  # proxy or OAuth endpoints. Example: `internal-https-search-probe` gets
  # `= /healthz` and the probe-vhost catch-all remains 404.
  vhostsFor =
    gate:
    lib.mapAttrs' (
      serviceName: locations: lib.nameValuePair (vhostNameFor serviceName) { inherit locations; }
    ) gate.probeLocationsByName;
}
