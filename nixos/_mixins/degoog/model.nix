{
  config,
  lib,
  outputs,
}:
let
  cfg = config.host.degoog;
  localHost = config.networking.hostName;
  resolveHost =
    hostName:
    if hostName == null then
      null
    else if hostName == localHost then
      config
    else if builtins.hasAttr hostName outputs.nixosConfigurations then
      outputs.nixosConfigurations.${hostName}.config
    else
      null;
  jellyfinHost = resolveHost cfg.integrations.jellyfin.host;
  rommHost = resolveHost cfg.integrations.romm.host;
  ssoApplication = config.host.sso.applications.${cfg.sso.application} or null;
  adminUsers =
    if ssoApplication == null || ssoApplication.adminGroup == null then
      { }
    else
      lib.filterAttrs (
        _: user: builtins.elem ssoApplication.adminGroup user.groups
      ) config.host.sso.users;
  integrationFeatures =
    lib.optional (cfg.integrations.jellyfin.host != null) "jellyfin"
    ++ lib.optional (cfg.integrations.romm.host != null) "romm";
  selectedFeatureNames = lib.unique ([ "settings-access" ] ++ cfg.features ++ integrationFeatures);
  select =
    catalog: names:
    map (name: catalog.${name}) (builtins.filter (name: builtins.hasAttr name catalog) names);
  selectedRegistrations =
    select cfg.catalog.engines cfg.engines
    ++ select cfg.catalog.features selectedFeatureNames
    ++ lib.optionals (cfg.theme != null && builtins.hasAttr cfg.theme cfg.catalog.themes) [
      cfg.catalog.themes.${cfg.theme}
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
    jellyfinHost
    rommHost
    selectedRegistrations
    ssoApplication
    ;
  jellyfin = if jellyfinHost == null then null else jellyfinHost.host.jellyfin;
  romm = if rommHost == null then null else rommHost.host.romm;
  jellyfinSelected = cfg.integrations.jellyfin.host != null;
  rommSelected = cfg.integrations.romm.host != null;
  unknownEngines = lib.subtractLists (builtins.attrNames cfg.catalog.engines) cfg.engines;
  unknownFeatures = lib.subtractLists (builtins.attrNames cfg.catalog.features) selectedFeatureNames;
  unknownTheme = cfg.theme != null && !builtins.hasAttr cfg.theme cfg.catalog.themes;
  invalidExtensions =
    builtins.filter
      (
        extension:
        builtins.match "^(autocomplete|engines|plugins|shortcuts|themes|transports)/[a-z0-9][a-z0-9._+-]*$" extension
        == null
      )
      (
        map (registration: registration.extension) (
          builtins.attrValues cfg.catalog.engines
          ++ builtins.attrValues cfg.catalog.features
          ++ builtins.attrValues cfg.catalog.themes
        )
      );
  duplicateExtensions = lib.unique (
    builtins.filter (
      extension: lib.count (candidate: candidate == extension) extensionNames > 1
    ) extensionNames
  );
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
