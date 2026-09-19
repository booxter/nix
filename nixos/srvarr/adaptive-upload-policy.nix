{ ... }:
{
  host.adaptiveUploadPolicy = {
    fallbackRateMbit = 8;
    night = {
      start = "00:00";
      end = "06:00";
      rateMbit = 30;
    };

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
