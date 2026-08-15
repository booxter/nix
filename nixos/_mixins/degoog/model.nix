{
  config,
  lib,
  outputs,
  pkgs,
}:
let
  cfg = config.host.degoog;
  packages = import ./packages.nix { inherit pkgs; };
  localHost = config.networking.hostName;
  resolveHost =
    hostName:
    if hostName == null then
      null
    else if hostName == localHost then
      config
    else
      outputs.nixosConfigurations.${hostName}.config;
  jellyfinHost = resolveHost cfg.integrations.jellyfin;
  rommHost = resolveHost cfg.integrations.romm;
  jellyfin = if jellyfinHost == null then null else jellyfinHost.host.jellyfin;
  jellyfinUrl =
    if jellyfinHost == null then null else jellyfinHost.host.web.services.jellyfin.public.url;
  romm = if rommHost == null then null else rommHost.host.romm;
  rommUrl = if rommHost == null then null else rommHost.host.web.services.romm.public.url;
  ssoApplication = config.host.sso.applications.degoog;
  adminUsers = lib.filterAttrs (
    _: user: builtins.elem ssoApplication.roles.admin user.groups
  ) config.host.sso.users;
  normalizeCatalog = lib.mapAttrs (
    _: registration:
    {
      source = null;
      settings = { };
      secretNames = [ ];
    }
    // registration
  );
  catalog = {
    engines = normalizeCatalog {
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

    features = normalizeCatalog {
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
        settings = {
          middleware.settingsGate = "plugin:trusted-header-settings-auth-middleware";
          trusted-header-settings-auth-middleware.allowedUsers = lib.concatStringsSep "," (
            builtins.attrNames adminUsers
          );
        };
      };
      weather.extension = "plugins/weather";
      jellyfin = {
        extension = "plugins/jellyfin";
        secretNames = [ "jellyfin_api_key" ];
        settings.degoog-org-official-extensions-jellyfin-command = {
          apiKey = config.sops.placeholder."degoog/jellyfin_api_key";
          headerName = "X-Emby-Token";
          url = jellyfinUrl;
        };
      };
      romm = {
        extension = "plugins/romm";
        secretNames = [ "romm_api_token" ];
        settings.degoog-org-official-extensions-romm-command = {
          apiToken = config.sops.placeholder."degoog/romm_api_token";
          url = if romm == null then null else romm.publicUrl;
        };
      };
    };

    themes = normalizeCatalog {
      gruvbox = {
        extension = "themes/georgvwt-georgvwt-degoog-stuff-gruvbox-theme";
        source = "${packages.georgvwtExtensions}/themes/gruvbox";
        settings.theme.active = "georgvwt-georgvwt-degoog-stuff-gruvbox-theme";
      };
    };
  };
  integrationFeatures =
    lib.optional (cfg.integrations.jellyfin != null) "jellyfin"
    ++ lib.optional (cfg.integrations.romm != null) "romm";
  selectedFeatureNames = lib.unique ([ "settings-access" ] ++ cfg.features ++ integrationFeatures);
  select = registrations: names: map (name: registrations.${name}) names;
  selectedRegistrations =
    select catalog.engines cfg.engines
    ++ select catalog.features selectedFeatureNames
    ++ lib.optionals (cfg.theme != null) [
      catalog.themes.${cfg.theme}
    ];
  extensionNames = map (registration: registration.extension) selectedRegistrations;
  settingNamespaces = lib.concatMap (
    registration: builtins.attrNames registration.settings
  ) selectedRegistrations;
in
{
  inherit
    adminUsers
    cfg
    extensionNames
    jellyfin
    jellyfinHost
    jellyfinUrl
    packages
    romm
    rommHost
    rommUrl
    selectedRegistrations
    ssoApplication
    ;
  jellyfinSelected = cfg.integrations.jellyfin != null;
  rommSelected = cfg.integrations.romm != null;
  duplicateSettingNamespaces = lib.unique (
    builtins.filter (
      namespace: lib.count (candidate: candidate == namespace) settingNamespaces > 1
    ) settingNamespaces
  );
  pluginSettings = lib.foldl' lib.recursiveUpdate { } (
    map (registration: registration.settings) selectedRegistrations
  );
  secretNames = lib.unique (
    [ "settings_password" ]
    ++ lib.concatMap (registration: registration.secretNames) selectedRegistrations
  );
}
