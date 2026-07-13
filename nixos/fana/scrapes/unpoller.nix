{ }:
let
  unpollerPort = 9130;
in
{
  scrapeConfigs = [
    {
      job_name = "unpoller";
      scrape_interval = "60s";
      scrape_timeout = "30s";
      static_configs = [
        {
          targets = [ "127.0.0.1:${toString unpollerPort}" ];
          labels.instance = "unifi";
        }
      ];
    }
  ];
}
