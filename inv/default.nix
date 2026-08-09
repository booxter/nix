{ lib }:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  lanDnsRecordTtlSeconds = 300;
  lanDomain = "home.arpa";
  publicDomain = "ihar.dev";

  frame = "frame";
  mmini = "mmini";

  siteFacts = import ./site.nix { inherit lanDomain publicDomain readPublicKey; };
  realms = import ./realms.nix {
    inherit lanDomain readPublicKey;
    nixCaches = siteFacts.nixCaches;
  };
  hostFactsFor = import ./hosts.nix { inherit frame lib; };
  backupFacts = import ./backups.nix { inherit readPublicKey; };
  backupLinks = lib.mapAttrs (
    clientName:
    lib.mapAttrs (
      linkName: link:
      let
        provider = backupFacts.providers.${link.provider};
        storageName = link.storageName or clientName;
      in
      link
      // {
        inherit clientName linkName storageName;
        repositoryPath = "${provider.repositoryRoot}/${storageName}";
        ingestUser = "restic-${clientName}";
      }
    )
  ) backupFacts.links;
  hostFacts = hostFactsFor {
    inherit lanDomain;
  };
  realmFor =
    spec:
    let
      realmName = spec.realm or (throw "host ${spec.name} does not declare a realm");
    in
    realms.${realmName} or (throw "host ${spec.name} declares unknown realm '${realmName}'");
  normalizeHostSpec = spec: builtins.seq (realmFor spec) spec;
  normalizedDarwinHosts = lib.mapAttrs (_: normalizeHostSpec) hostFacts.darwinHosts;
  normalizedNixosHostSpecs = map normalizeHostSpec hostFacts.nixosHostSpecs;

  sshTicketFacts = import ./ssh-ticket.nix {
    inherit
      lib
      frame
      mmini
      readPublicKey
      realms
      ;
    darwinHosts = normalizedDarwinHosts;
    nixosHostSpecs = normalizedNixosHostSpecs;
  };
  ssoFacts = import ./sso.nix;
  yubiFacts = import ./yubi.nix { inherit frame mmini; };
  upsFacts = import ./ups.nix;

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
  inherit lanDomain;

  backups = backupFacts // {
    links = backupLinks;
  };

  inherit realms;

  sshTicket = sshTicketFacts;
  sso = ssoFacts;
  yubi = yubiFacts;
  ups = upsFacts;

  toLocalDnsName = label: "${label}.local";
  toSshKnownHostNames =
    domain: spec:
    let
      inherit (spec) name;
      lowercaseName = lib.toLower name;
    in
    lib.unique (
      [ name ]
      ++ lib.optional (lowercaseName != name) lowercaseName
      ++ lib.optional (lib.hasSuffix "-linux" spec.platform) "${name}.${domain}"
      ++ [ (toLocalDnsName name) ]
      ++ lib.optional (lowercaseName != name) (toLocalDnsName lowercaseName)
    );
  toNixosHostCertificateDnsNames = domain: spec: [
    spec.name
    "${spec.name}.${domain}"
    (toLocalDnsName spec.name)
  ];
  toHostIpv4Address = aliasIpv4Address;
  toNixosHostIpv4Address = name: toHostIpv4Address nixosHosts.${name};
  toUpsName = name: "${lib.strings.toUpper name}-UPS";
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
          staticDnsRecords = [
            (mkDnsARecord "unifi.${lanDomain}" siteFacts.lan.gateway.address)
          ];
          renderHostDnsRecords =
            spec:
            (map (domain: mkDnsARecord domain (aliasIpv4Address spec)) (spec.dnsAliases or [ ]))
            ++ map (label: mkDnsARecord "${label}.${lanDomain}" (aliasIpv4Address spec)) (
              lib.unique (spec.localDnsAliases or [ ])
            );
        in
        staticDnsRecords ++ builtins.concatMap renderHostDnsRecords nixosHostSpecs;
    };
  };

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

}
