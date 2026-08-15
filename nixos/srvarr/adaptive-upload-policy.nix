{ ... }:
{
  host.adaptiveUploadPolicy = {
    fallbackRateMbit = 8;

    source.jellyfin.host = "beast";

    destinations = {
      transmission = { };
      qos = {
        limit = "uplink";
        match.remotePort = 1637;
        maximumDownloadRateMbit = 400;
        accountingName = "wg";
      };
    };
  };
}
