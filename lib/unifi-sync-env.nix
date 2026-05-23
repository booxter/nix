{ hostInventory }:
let
  lan = hostInventory.site.lan;
  netboot = lan.netboot;
  netbootHost = hostInventory.nixosHostSpecsByName.${netboot.host};

  isMacAddress = identifier: builtins.match "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" identifier != null;

  reservationIdentifiers =
    reservation:
    if reservation ? identifiers then
      reservation.identifiers
    else if reservation ? match then
      [ reservation.match ]
    else
      [ ];

  reservationInventoryJson = builtins.toJSON (
    map
      (reservation: {
        inherit (reservation) hostname ip;
        mac = builtins.head (builtins.filter isMacAddress (reservationIdentifiers reservation));
      })
      (
        builtins.filter
          (reservation: builtins.any isMacAddress (reservationIdentifiers reservation))
          (hostInventory.managedDhcpReservations ++ hostInventory.staticDhcpReservations)
      )
  );

  mainDhcpRangeJson = builtins.toJSON (builtins.elemAt lan.dhcpRanges.main.ranges 0);
  mainDomainName = lan.domain;
  mainDomainSearchJson = builtins.toJSON [ lan.domain ];
  domainSearchOption =
    if lan ? customDhcpOptions && lan.customDhcpOptions ? domainSearch then
      lan.customDhcpOptions.domainSearch
    else
      null;

  networkTftpServer =
    if netbootHost ? lanAddress then
      netbootHost.lanAddress
    else if netbootHost ? ipAddress then
      netbootHost.ipAddress
    else
      throw "netboot host ${netboot.host} does not expose a stable IPv4 address";

  networkBootfile = netboot.bootfile;
  dnsRecordsJson = builtins.toJSON lan.dnsRecords;

  baseUrl = "https://${lan.gateway.address}";
  site = "default";
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
    ;

  environment =
    {
      UNIFI_BASE_URL = baseUrl;
      UNIFI_SITE = site;
      UNIFI_RESERVATION_INVENTORY_JSON = reservationInventoryJson;
      UNIFI_NETWORK_DHCP_RANGE_JSON = mainDhcpRangeJson;
      UNIFI_NETWORK_DOMAIN_NAME = mainDomainName;
      UNIFI_NETWORK_DOMAIN_SEARCH_JSON = mainDomainSearchJson;
      UNIFI_NETWORK_DOMAIN_SEARCH_OPTION_JSON =
        if domainSearchOption != null then builtins.toJSON domainSearchOption else "";
      UNIFI_NETWORK_TFTP_SERVER = networkTftpServer;
      UNIFI_NETWORK_BOOTFILE = networkBootfile;
      UNIFI_DNS_RECORDS_JSON = dnsRecordsJson;
    }
    ;
}
