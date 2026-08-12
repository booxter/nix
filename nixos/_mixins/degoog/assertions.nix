{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model)
    adminUsers
    cfg
    duplicateExtensions
    duplicateSettingNamespaces
    invalidExtensions
    jellyfin
    jellyfinHost
    romm
    rommHost
    ssoApplication
    unknownEngines
    unknownFeatures
    unknownTheme
    ;
in
{
  assertions = lib.optionals cfg.enable [
    {
      assertion = unknownEngines == [ ];
      message = "Degoog selects unknown engines: ${lib.concatStringsSep ", " unknownEngines}";
    }
    {
      assertion = unknownFeatures == [ ];
      message = "Degoog selects unknown features: ${lib.concatStringsSep ", " unknownFeatures}";
    }
    {
      assertion = !unknownTheme;
      message = "Degoog selects an unknown theme: ${toString cfg.theme}";
    }
    {
      assertion = lib.unique cfg.engines == cfg.engines;
      message = "host.degoog.engines must not contain duplicates.";
    }
    {
      assertion = lib.unique cfg.features == cfg.features;
      message = "host.degoog.features must not contain duplicates.";
    }
    {
      assertion = invalidExtensions == [ ];
      message = "Degoog catalog entries use invalid extension paths: ${lib.concatStringsSep ", " invalidExtensions}";
    }
    {
      assertion = duplicateExtensions == [ ];
      message = "Degoog selections resolve to duplicate extensions: ${lib.concatStringsSep ", " duplicateExtensions}";
    }
    {
      assertion = duplicateSettingNamespaces == [ ];
      message = "Degoog extensions contribute conflicting settings: ${lib.concatStringsSep ", " duplicateSettingNamespaces}";
    }
    {
      assertion = ssoApplication != null;
      message = "host.degoog.sso.application must name a declared SSO application.";
    }
    {
      assertion = ssoApplication == null || ssoApplication.adminGroup != null;
      message = "The Degoog SSO application must declare an administrator group.";
    }
    {
      assertion = ssoApplication == null || ssoApplication.userGroup != null;
      message = "The Degoog SSO application must declare a user group.";
    }
    {
      assertion = adminUsers != { };
      message = "The Degoog SSO application has no settings administrators.";
    }
    {
      assertion = !model.jellyfinSelected || jellyfinHost != null;
      message = "host.degoog.integrations.jellyfin.host must name a known NixOS host.";
    }
    {
      assertion = !model.jellyfinSelected || (jellyfin != null && jellyfin.enable);
      message = "The selected Degoog Jellyfin integration host must enable Jellyfin.";
    }
    {
      assertion = !model.jellyfinSelected || (jellyfin != null && jellyfin.publicUrl != null);
      message = "The selected Degoog Jellyfin integration requires a public Jellyfin URL.";
    }
    {
      assertion =
        !model.jellyfinSelected || (jellyfinHost != null && jellyfinHost.host.realm == config.host.realm);
      message = "Degoog and its Jellyfin integration must be in the same realm.";
    }
    {
      assertion = !model.rommSelected || rommHost != null;
      message = "host.degoog.integrations.romm.host must name a known NixOS host.";
    }
    {
      assertion = !model.rommSelected || (romm != null && romm.enable);
      message = "The selected Degoog RomM integration host must enable RomM.";
    }
    {
      assertion = !model.rommSelected || (romm != null && romm.publicUrl != null);
      message = "The selected Degoog RomM integration requires a public RomM URL.";
    }
    {
      assertion = !model.rommSelected || (rommHost != null && rommHost.host.realm == config.host.realm);
      message = "Degoog and its RomM integration must be in the same realm.";
    }
  ];
}
