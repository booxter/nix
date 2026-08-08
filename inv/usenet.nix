let
  server =
    host: overrides:
    {
      inherit host;
      name = host;
      displayname = host;
      port = 563;
      timeout = 90;
      connections = 10;
      ssl = true;
      ssl_verify = 3;
      ssl_ciphers = "";
      enable = true;
      required = false;
      optional = false;
      pipelining_requests = 1;
      retention = 0;
      expire_date = "";
      quota = "";
      usage_at_start = 0;
      priority = 1;
      notes = "";
    }
    // overrides;
in
{
  sabnzbd.servers = {
    "news.frugalusenet.com" = server "news.frugalusenet.com" {
      connections = 75;
      required = true;
    };
    "news.newshosting.com" = server "news.newshosting.com" {
      connections = 75;
      required = true;
    };
    "eunews.frugalusenet.com" = server "eunews.frugalusenet.com" {
      enable = false;
      priority = 7;
      timeout = 120;
    };
    "bonus.frugalusenet.com" = server "bonus.frugalusenet.com" {
      priority = 20;
    };
    "usnews.blocknews.net" = server "usnews.blocknews.net" {
      connections = 20;
      enable = false;
      priority = 25;
    };
    "reader.easyusenet.nl" = server "reader.easyusenet.nl" {
      connections = 75;
      required = true;
      ssl_verify = 2;
    };
  };
}
