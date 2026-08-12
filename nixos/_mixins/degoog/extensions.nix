{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.degoog;
  packages = import ./packages.nix { inherit pkgs; };
in
{
  config = lib.mkIf cfg.enable {
    host.degoog.catalog = {
      engines = {
        brave.extension = "engines/brave";
        brave-images.extension = "engines/brave-images";
        brave-news.extension = "engines/brave-news";
        openstreetmap = {
          extension = "engines/devinside-devinside-degoog-osmapp-maps";
          source = "${packages.devinsideExtensions}/engines/osmapp-maps";
        };
        duckduckgo.extension = "engines/duckduckgo";
        duckduckgo-images.extension = "engines/duckduckgo-images";
        duckduckgo-news.extension = "engines/duckduckgo-news";
        google.extension = "engines/google-cse";
        hacker-news.extension = "engines/hacker-news";
        internet-archive.extension = "engines/internet-archive";
        stackexchange = {
          extension = "engines/pross-degoog-stackexchange-engine-stackexchange";
          source = packages.stackexchangeEngine;
          secretNames = [ "stackexchange_api_key" ];
          settings.pross-degoog-stackexchange-engine-stackexchange-engine.apiKey =
            config.sops.placeholder."degoog/stackexchange_api_key";
        };
        reddit = {
          extension = "engines/reddit";
          settings.degoog-org-official-extensions-reddit-engine.includeNsfw = "true";
        };
        wikipedia.extension = "engines/wikipedia";
      };

      features = {
        brave-autocomplete.extension = "autocomplete/brave";
        duckduckgo-bangs.extension = "plugins/ddg-bang";
        definitions.extension = "plugins/define";
        local-history = {
          extension = "plugins/devinside-devinside-degoog-local-history";
          source = "${packages.devinsideExtensions}/plugins/local-history";
        };
        openstreetmap-results = {
          extension = "plugins/georgvwt-georgvwt-degoog-stuff-osm-slot";
          source = "${packages.georgvwtExtensions}/plugins/osm-slot";
        };
        reddit-results = {
          extension = "plugins/georgvwt-georgvwt-degoog-stuff-reddit-slot";
          source = "${packages.georgvwtExtensions}/plugins/reddit-slot";
          settings.georgvwt-georgvwt-degoog-stuff-reddit-slot.filterNsfw = false;
        };
        github-results = {
          extension = "plugins/github-slot";
          secretNames = [ "github_api_token" ];
          settings.degoog-org-official-extensions-github-slot.apiToken =
            config.sops.placeholder."degoog/github_api_token";
        };
        highlight-terms.extension = "plugins/highlight-terms";
        math.extension = "plugins/math-slot";
        stocks = {
          extension = "plugins/sopat712-degoog-toolkit-stocks";
          source = "${packages.toolkitExtensions}/plugins/stocks";
        };
        time.extension = "plugins/time";
        tmdb-results = {
          extension = "plugins/tmdb-slot";
          secretNames = [ "tmdb_api_key" ];
          settings.degoog-org-official-extensions-tmdb-slot.apiKey =
            config.sops.placeholder."degoog/tmdb_api_key";
        };
        settings-access = {
          extension = "plugins/trusted-header-settings-auth";
          source = packages.trustedHeaderSettingsAuth;
        };
        weather.extension = "plugins/weather";
      };

      themes.gruvbox = {
        extension = "themes/georgvwt-georgvwt-degoog-stuff-gruvbox-theme";
        source = "${packages.georgvwtExtensions}/themes/gruvbox";
        settings.theme.active = "georgvwt-georgvwt-degoog-stuff-gruvbox-theme";
      };
    };
  };
}
