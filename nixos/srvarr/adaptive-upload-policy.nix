{ ... }:
{
  host.adaptiveUploadPolicy = {
    enable = true;
    fallbackRateMbit = 8;

    source.jellyfin.host = "beast";

    destinations = {
      downloadClients.transmission.client = "transmission";
      qos.uplink = {
        match.remotePort = 1637;
        maximumDownloadRateMbit = 400;
        accountingName = "wg";
      };
    };
  };
}
