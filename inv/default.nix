{
  lib,
  username ? "ihrachyshka",
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  lanDnsRecordTtlSeconds = 300;
  lanDomain = "home.arpa";
  publicDomain = "ihar.dev";

  frame = "frame";
  mmini = "mmini";

  realms = import ./realms.nix { inherit lanDomain; };
  hostFactsFor = import ./hosts.nix { inherit frame lib; };
  backupFacts = import ./backups.nix { inherit readPublicKey; };
  backupClients = lib.mapAttrs (
    name: client:
    client
    // rec {
      storageName = client.storageName or name;
      repositoryPath = "${backupFacts.server.repositoryRoot}/${storageName}";
      ingestUser = "restic-${name}";
    }
  ) backupFacts.clients;
  serviceFacts = import ./services.nix { inherit publicDomain; };
  glanceCategoryIds = map (category: category.id) serviceFacts.glanceCategories;
  publicServiceHosts = map (service: service.publicHost) (
    builtins.filter (service: service ? publicHost) serviceFacts.definitions
  );
  hostFacts = hostFactsFor {
    inherit lanDomain publicDomain publicServiceHosts;
  };
  realmFor =
    spec:
    let
      realmName = spec.realm or (throw "host ${spec.name} does not declare a realm");
    in
    realms.${realmName} or (throw "host ${spec.name} declares unknown realm '${realmName}'");
  normalizeHostSpec = spec: builtins.seq (realmFor spec) ({ inherit username; } // spec);
  normalizedDarwinHosts = lib.mapAttrs (_: normalizeHostSpec) hostFacts.darwinHosts;
  normalizedNixosHostSpecs = map normalizeHostSpec hostFacts.nixosHostSpecs;

  sshTicketFacts = import ./ssh-ticket.nix {
    inherit
      lib
      frame
      mmini
      readPublicKey
      username
      ;
    darwinHosts = normalizedDarwinHosts;
    nixosHostSpecs = normalizedNixosHostSpecs;
  };
  ssoFacts = import ./sso.nix;
  siteFacts = import ./site.nix { inherit lanDomain publicDomain readPublicKey; };
  yubiFacts = import ./yubi.nix { inherit frame mmini username; };

  normalizeService =
    glanceCategoryIds: localDnsName:
    {
      id,
      owner,
      probePath,
      publicHost ? null,
      title ? lib.strings.toSentenceCase id,
      icon ? "sh:${id}",
      blackboxProbe ? true,
      backendProbe ? null,
      glanceCategory ? null,
      internalEndpointName ? id,
    }:
    let
      scope = if publicHost == null then "internal" else "external";
      showInGlance = glanceCategory != null;
      service = {
        inherit
          blackboxProbe
          glanceCategory
          icon
          id
          internalEndpointName
          owner
          probePath
          scope
          showInGlance
          title
          ;
      }
      // lib.optionalAttrs (backendProbe != null) { inherit backendProbe; }
      // lib.optionalAttrs (publicHost != null) { inherit publicHost; };
      resolvedService =
        service
        // lib.optionalAttrs (service ? publicHost) (rec {
          inherit (service) publicHost;
          url = "https://${publicHost}";
          probeUrl = "${url}${service.probePath}";
        })
        // lib.optionalAttrs (service.scope == "internal") {
          displayHost = localDnsName owner;
          probeHost = owner;
        };
      category = glanceCategory;
      categoryLabel = if category == null then "<missing>" else category;
    in
    assert lib.asserts.assertMsg (
      category == null || builtins.elem category glanceCategoryIds
    ) "Glance service ${service.id} uses unknown glanceCategory '${categoryLabel}'";
    resolvedService;

  serviceLocalDnsAliases =
    services: owner:
    map (service: service.internalEndpointName) (
      builtins.filter (service: service.owner == owner && service.internalEndpointName != null) services
    );

  mkDnsARecord = domain: ipv4Address: {
    type = "A_RECORD";
    ttlSeconds = lanDnsRecordTtlSeconds;
    inherit domain ipv4Address;
  };
  aliasIpv4Address =
    spec:
    if spec ? dhcpReservation then
      spec.dhcpReservation.ip
    else if spec ? ipAddress then
      spec.ipAddress
    else
      throw "host ${spec.name} does not have a stable IPv4 address";
in
rec {
  backups = backupFacts // {
    clients = backupClients;
  };

  inherit (serviceFacts) glanceCategories;
  inherit realms;

  sshTicket = sshTicketFacts;
  sso = ssoFacts;
  yubi = yubiFacts;

  toLocalDnsName = label: "${label}.local";
  toSshKnownHostNames =
    spec:
    let
      inherit (spec) name;
      lowercaseName = lib.toLower name;
    in
    lib.unique (
      [ name ]
      ++ lib.optional (lowercaseName != name) lowercaseName
      ++ lib.optional (lib.hasSuffix "-linux" spec.platform) "${name}.${site.lan.domain}"
      ++ [ (toLocalDnsName name) ]
      ++ lib.optional (lowercaseName != name) (toLocalDnsName lowercaseName)
    );
  toInternalHttpsServiceHosts =
    serviceName:
    let
      endpointName = servicesById.${serviceName}.internalEndpointName;
    in
    if endpointName == null then
      throw "service ${serviceName} does not have an internal HTTPS endpoint"
    else
      [
        "${endpointName}.${site.lan.domain}"
        endpointName
        (toLocalDnsName endpointName)
      ];
  toNixosHostCertificateDnsNames = spec: [
    spec.name
    "${spec.name}.${site.lan.domain}"
    (toLocalDnsName spec.name)
  ];
  toHostIpv4Address = aliasIpv4Address;
  toNixosHostIpv4Address = name: toHostIpv4Address nixosHosts.${name};
  toUpsName = name: "${lib.strings.toUpper name}-UPS";
  srvarrAdminAppIds = map (service: service.id) (
    builtins.filter (
      service: service.owner == "srvarr" && service.glanceCategory == "media-admin"
    ) services
  );
  site = siteFacts // {
    lan = siteFacts.lan // {
      staticRoutes = [
        {
          name = "wg-home";
          destination = siteFacts.wireguard.home.cidr;
          nextHop = toNixosHostIpv4Address siteFacts.wireguard.home.gateway.host;
          distance = 1;
        }
      ];

      dnsRecords =
        let
          lanDomain = siteFacts.lan.domain;
          staticDnsRecords = [
            (mkDnsARecord "unifi.${lanDomain}" siteFacts.lan.gateway.address)
          ];
          renderHostDnsRecords =
            spec:
            (map (domain: mkDnsARecord domain (aliasIpv4Address spec)) (spec.dnsAliases or [ ]))
            ++ map (label: mkDnsARecord "${label}.${lanDomain}" (aliasIpv4Address spec)) (
              lib.unique ((spec.localDnsAliases or [ ]) ++ serviceLocalDnsAliases services spec.name)
            );
        in
        staticDnsRecords ++ builtins.concatMap renderHostDnsRecords nixosHostSpecs;
    };
  };

  services = map (normalizeService glanceCategoryIds toLocalDnsName) serviceFacts.definitions;

  darwinHosts = normalizedDarwinHosts;
  nixosHostSpecs = normalizedNixosHostSpecs;
  inherit (hostFacts) staticDhcpReservations;

  managedDhcpReservations = map (spec: spec.dhcpReservation // { hostname = spec.name; }) (
    builtins.filter (spec: spec ? dhcpReservation) nixosHostSpecs
  );

  dhcpReservationsByHostname = builtins.listToAttrs (
    map (reservation: {
      name = reservation.hostname;
      value = reservation;
    }) (managedDhcpReservations ++ staticDhcpReservations)
  );

  nixosHosts = builtins.listToAttrs (
    map (spec: {
      name = spec.name;
      value = spec;
    }) nixosHostSpecs
  );

  hostSpecsByName = darwinHosts // nixosHosts;

  secretDomainsByHost = lib.mapAttrs (_: spec: (realmFor spec).secretDomain) hostSpecsByName;

  systemsByHost = lib.mapAttrs (_: spec: spec.platform) hostSpecsByName;

  publicServices = builtins.filter (service: service.scope == "external") services;

  servicesById = builtins.listToAttrs (
    map (service: {
      name = service.id;
      value = service;
    }) services
  );
}
