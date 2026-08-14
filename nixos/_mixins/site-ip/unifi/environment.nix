{
  addressFor,
  baseUrl,
  lan,
  lanDomain,
  reservations,
  site,
  staticRoutes ? [ ],
  webDnsRecords ? [ ],
}:
let
  netboot = lan.netboot;

  reservationInventoryJson = builtins.toJSON (
    map (
      hostname:
      let
        reservation = reservations.${hostname};
      in
      {
        inherit hostname;
        ip = reservation.address;
        mac = reservation.macAddress;
      }
    ) (builtins.attrNames reservations)
  );

  mainDhcpRangeJson = builtins.toJSON (builtins.elemAt lan.dhcp.ranges.main 0);
  mainDomainName = lanDomain;
  mainDomainSearchJson = builtins.toJSON [ lanDomain ];
  domainSearchOption =
    if lan ? customDhcpOptions && lan.customDhcpOptions ? domainSearch then
      lan.customDhcpOptions.domainSearch
    else
      null;
  classlessStaticRoutesOption =
    if lan ? customDhcpOptions && lan.customDhcpOptions ? classlessStaticRoutes then
      lan.customDhcpOptions.classlessStaticRoutes
    else
      null;

  networkTftpServer = addressFor netboot.host;

  networkBootfile = netboot.bootFile;
  dnsRecordsByDomain = builtins.listToAttrs (
    map
      (record: {
        name = record.domain;
        value = record;
      })
      (
        webDnsRecords
        ++ [
          {
            type = "A_RECORD";
            ttlSeconds = 300;
            domain = "unifi.${lanDomain}";
            ipv4Address = lan.gateway.address;
          }
        ]
      )
  );
  dnsRecordsJson = builtins.toJSON (builtins.attrValues dnsRecordsByDomain);
  renderedStaticRoutes = map (
    route:
    removeAttrs route [ "nextHopHost" ]
    // {
      nextHop = addressFor route.nextHopHost;
    }
  ) staticRoutes;
  staticRoutesJson = builtins.toJSON renderedStaticRoutes;
  classlessStaticRoutesJson = builtins.toJSON (
    (builtins.filter (route: route.enabled or true) renderedStaticRoutes)
    ++ [
      {
        name = "default";
        destination = "0.0.0.0/0";
        nextHop = lan.gateway.address;
      }
    ]
  );

in
{
  inherit
    baseUrl
    site
    reservationInventoryJson
    mainDhcpRangeJson
    mainDomainName
    mainDomainSearchJson
    networkTftpServer
    networkBootfile
    dnsRecordsJson
    staticRoutesJson
    classlessStaticRoutesJson
    ;

  environment = {
    UNIFI_BASE_URL = baseUrl;
    UNIFI_SITE = site;
    UNIFI_RESERVATION_INVENTORY_JSON = reservationInventoryJson;
    UNIFI_NETWORK_DHCP_RANGE_JSON = mainDhcpRangeJson;
    UNIFI_NETWORK_DOMAIN_NAME = mainDomainName;
    UNIFI_NETWORK_DOMAIN_SEARCH_JSON = mainDomainSearchJson;
    UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_JSON =
      if domainSearchOption != null then builtins.toJSON domainSearchOption else "";
    UNIFI_CLASSLESS_STATIC_ROUTES_JSON = classlessStaticRoutesJson;
    UNIFI_CLASSLESS_STATIC_ROUTES_OPTION_JSON =
      if classlessStaticRoutesOption != null then builtins.toJSON classlessStaticRoutesOption else "";
    UNIFI_NETWORK_TFTP_SERVER = networkTftpServer;
    UNIFI_NETWORK_BOOTFILE = networkBootfile;
    UNIFI_DNS_RECORDS_JSON = dnsRecordsJson;
    UNIFI_STATIC_ROUTES_JSON = staticRoutesJson;
  };
}
