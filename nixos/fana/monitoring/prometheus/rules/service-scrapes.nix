{ lib }:
let
  inherit (import ./lib.nix { inherit lib; }) mkGroup mkScrapeDown;
in
{
  groups = [
    (mkGroup {
      name = "service-scrapes";
      rules = [
        (mkScrapeDown {
          name = "ApplicationMetricsScrapeDown";
          selector = ''up{scrape_profile="application",availability!="intermittent"}'';
          for = "5m";
          category = "service";
          summary = "Application metrics scrape down: {{ $labels.service }} on {{ $labels.instance }}";
          description = "Prometheus has been unable to scrape {{ $labels.service }} metrics on {{ $labels.instance }} for 5 minutes.";
        })
      ];
    })
  ];
}
