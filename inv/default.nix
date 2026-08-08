{ lib }:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  lanDnsRecordTtlSeconds = 300;
  lanDomain = "home.arpa";
  publicDomain = "ihar.dev";

  frame = "frame";
  mmini = "mmini";
  user = import ./user.nix;
  fleetRepository = import ./repository.nix;
  regional = import ./regional.nix;
  serviceAccounts = import ./service-accounts.nix;
  atticFacts = import ./attic.nix { inherit lanDomain; };
  autoUpgradeFacts = import ./auto-upgrade { inherit lib; };
  inherit (user) username;

  siteFacts = import ./site.nix {
    attic = atticFacts;
    inherit lanDomain publicDomain readPublicKey;
  };
  realms = import ./realms.nix {
    attic = atticFacts;
    inherit
      backupFacts
      lanDomain
      readPublicKey
      user
      ;
    nixCaches = siteFacts.nixCaches;
    ssh = sshFacts;
  };
  hostFactsFor = import ./hosts.nix { inherit frame lib; };
  backupFacts = import ./backups.nix { inherit readPublicKey; };
  serviceFacts = import ./services.nix {
    inherit publicDomain;
    llmProviderHost = realms.home.services.llm.providerHost;
  };
  serviceOwnersById = builtins.listToAttrs (
    map (service: {
      name = service.id;
      value = service.owner;
    }) serviceFacts.definitions
  );
  storageFacts = import ./storage.nix;
  normalizeNfsExport =
    name: export:
    let
      clientServices = export.clientServices or [ ];
      unknownClientServices = builtins.filter (
        service: !builtins.hasAttr service serviceOwnersById
      ) clientServices;
      serviceClients = map (service: serviceOwnersById.${service}) clientServices;
    in
    assert lib.assertMsg (unknownClientServices == [ ])
      "NFS export '${name}' references unknown services: ${lib.concatStringsSep ", " unknownClientServices}";
    export
    // {
      clients = builtins.filter (client: client != export.server) (
        lib.unique ((export.clientHosts or [ ]) ++ serviceClients)
      );
    };
  normalizedStorageFacts = storageFacts // {
    nfs.exports = lib.mapAttrs normalizeNfsExport storageFacts.nfs.exports;
  };
  displayFacts = import ./displays.nix;
  upsFacts = import ./ups.nix;
  glanceCategoryIds = map (category: category.id) serviceFacts.glanceCategories;
  publicServiceHosts = map (service: service.publicHost) (
    builtins.filter (service: service ? publicHost) serviceFacts.definitions
  );
  hostFacts = hostFactsFor {
    inherit lanDomain publicDomain publicServiceHosts;
  };
  rawHostSpecs = hostFacts.nixosHostSpecs ++ builtins.attrValues hostFacts.darwinHosts;
  rawHostNames = map (spec: spec.name) rawHostSpecs;
  displayConnections = lib.concatMap (
    kvmName:
    lib.mapAttrsToList (hostName: connection: {
      inherit
        connection
        hostName
        kvmName
        ;
    }) displayFacts.kvms.${kvmName}.connections
  ) (builtins.attrNames displayFacts.kvms);
  displayConnectionHostNames = map (entry: entry.hostName) displayConnections;
  unknownDisplayHosts = lib.subtractLists rawHostNames displayConnectionHostNames;
  duplicateDisplayHosts = builtins.filter (
    hostName: builtins.length (builtins.filter (name: name == hostName) displayConnectionHostNames) > 1
  ) (lib.unique displayConnectionHostNames);
  validateDisplayConnection =
    entry:
    let
      kvm = displayFacts.kvms.${entry.kvmName};
      monitorNames = builtins.attrNames kvm.monitors;
      layoutNames = builtins.attrNames kvm.layout;
      connectorNames = builtins.attrNames (entry.connection.connectors or { });
      primary = entry.connection.primary or null;
    in
    assert lib.assertMsg (
      lib.subtractLists monitorNames layoutNames == [ ]
      && lib.subtractLists layoutNames monitorNames == [ ]
    ) "KVM '${entry.kvmName}' layout must cover exactly its monitors";
    assert lib.assertMsg (
      lib.subtractLists monitorNames connectorNames == [ ]
    ) "KVM '${entry.kvmName}' host '${entry.hostName}' references unknown monitors";
    assert lib.assertMsg (
      primary == null || builtins.elem primary monitorNames
    ) "KVM '${entry.kvmName}' host '${entry.hostName}' selects an unknown primary monitor";
    assert lib.assertMsg (
      builtins.length (builtins.attrValues (entry.connection.connectors or { }))
      == builtins.length (lib.unique (builtins.attrValues (entry.connection.connectors or { })))
    ) "KVM '${entry.kvmName}' host '${entry.hostName}' reuses a display connector";
    entry;
  checkedDisplayConnections =
    assert lib.assertMsg (
      unknownDisplayHosts == [ ]
    ) "KVM connections reference unknown hosts: ${lib.concatStringsSep ", " unknownDisplayHosts}";
    assert lib.assertMsg (
      duplicateDisplayHosts == [ ]
    ) "Hosts belong to multiple KVMs: ${lib.concatStringsSep ", " duplicateDisplayHosts}";
    map validateDisplayConnection displayConnections;
  displaysByHost = builtins.listToAttrs (
    map (
      entry:
      let
        kvm = displayFacts.kvms.${entry.kvmName};
        connection = entry.connection;
      in
      {
        name = entry.hostName;
        value = {
          kvm = entry.kvmName;
          drmCard = connection.drmCard or null;
          scale = connection.scale or null;
          primary = connection.primary or null;
          monitors = lib.mapAttrs (
            name: monitor:
            monitor
            // kvm.layout.${name}
            // {
              connector = connection.connectors.${name} or null;
            }
          ) kvm.monitors;
        };
      }
    ) checkedDisplayConnections
  );
  builderFacts = import ./builders.nix {
    inherit
      lib
      readPublicKey
      username
      ;
    githubLogin = user.github.login;
    hostSpecs = rawHostSpecs;
  };
  sshFacts = import ./ssh.nix {
    inherit lib readPublicKey username;
    hostSpecs = rawHostSpecs;
  };
  realmFor =
    spec:
    let
      realmName = spec.realm or (throw "host ${spec.name} does not declare a realm");
    in
    realms.${realmName} or (throw "host ${spec.name} declares unknown realm '${realmName}'");
  normalizeHostSpec =
    spec:
    let
      realm = realmFor spec;
      network =
        lib.optionalAttrs (spec.isVM or false) {
          primaryInterface = "ens18";
        }
        // (spec.network or { });
      serviceLocalDnsAliases = lib.concatMap (
        service:
        lib.optional (
          (service.serverHost or null) == spec.name && service ? localDnsName
        ) service.localDnsName
      ) (builtins.attrValues realm.services);
      localDnsAliases = lib.unique ((spec.localDnsAliases or [ ]) ++ serviceLocalDnsAliases);
    in
    builtins.seq realm (
      {
        inherit username;
      }
      // spec
      // lib.optionalAttrs (network != { }) { inherit network; }
      // lib.optionalAttrs (localDnsAliases != [ ]) { inherit localDnsAliases; }
    );
  normalizedDarwinHosts = lib.mapAttrs (_: normalizeHostSpec) hostFacts.darwinHosts;
  normalizedNixosHostSpecs = map normalizeHostSpec hostFacts.nixosHostSpecs;

  sshTicketFacts = import ./ssh-ticket.nix {
    inherit
      lib
      frame
      mmini
      realms
      username
      ;
    ssh = sshFacts;
    darwinHosts = normalizedDarwinHosts;
    nixosHostSpecs = normalizedNixosHostSpecs;
  };
  ssoFacts = import ./sso.nix;
  yubiFacts = import ./yubi.nix {
    inherit
      frame
      mmini
      username
      ;
    ssh = sshFacts;
  };

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
  autoUpgrade = autoUpgradeFacts;
  builders = builderFacts;

  inherit (serviceFacts) glanceCategories;
  inherit
    fleetRepository
    realms
    regional
    serviceAccounts
    user
    ;
  storage = normalizedStorageFacts;
  displays = displayFacts;
  inherit displaysByHost;
  ups = upsFacts;

  sshTicket = sshTicketFacts;
  ssh = sshFacts;
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
      staticRoutes = lib.mapAttrsToList (name: endpoint: {
        name = "wg-${name}";
        destination = endpoint.cidr;
        nextHop = toNixosHostIpv4Address endpoint.gateway.host;
        distance = 1;
      }) siteFacts.wireguard;

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
