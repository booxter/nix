{ ... }:
{
  host.sabnzbd = {
    servers = {
      "news.frugalusenet.com" = {
        connections = 75;
        required = true;
        priority = 1;
      };
      "news.newshosting.com" = {
        connections = 75;
        required = true;
        priority = 1;
      };
      "eunews.frugalusenet.com" = {
        timeout = 120;
        connections = 10;
        enable = false;
        priority = 7;
      };
      "bonus.frugalusenet.com" = {
        connections = 10;
        priority = 20;
      };
      "usnews.blocknews.net" = {
        connections = 20;
        enable = false;
        priority = 25;
      };
      "reader.easyusenet.nl" = {
        connections = 75;
        tls.verify = 2;
        required = true;
        priority = 1;
      };
    };
  };
}
