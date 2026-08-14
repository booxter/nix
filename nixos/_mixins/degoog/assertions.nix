{
  config,
  degoogModel,
  lib,
  ...
}:
let
  inherit (degoogModel)
    adminUsers
    cfg
    duplicateSettingNamespaces
    jellyfin
    jellyfinHost
    jellyfinUrl
    romm
    rommHost
    ssoApplication
    ;
in
{
  assertions = lib.optionals cfg.enable [
    {
      assertion = duplicateSettingNamespaces == [ ];
      message = "Degoog extensions contribute conflicting settings: ${lib.concatStringsSep ", " duplicateSettingNamespaces}";
    }
    {
      assertion = ssoApplication.adminGroup != null;
      message = "The Degoog SSO application must declare an administrator group.";
    }
    {
      assertion = ssoApplication.userGroup != null;
      message = "The Degoog SSO application must declare a user group.";
    }
    {
      assertion = adminUsers != { };
      message = "The Degoog SSO application has no settings administrators.";
    }
    {
      assertion = !degoogModel.jellyfinSelected || jellyfin != null;
      message = "The selected Degoog Jellyfin integration host must enable Jellyfin.";
    }
    {
      assertion = !degoogModel.jellyfinSelected || jellyfinUrl != null;
      message = "The selected Degoog Jellyfin integration requires a public Jellyfin URL.";
    }
    {
      assertion = !degoogModel.jellyfinSelected || jellyfinHost.host.realm == config.host.realm;
      message = "Degoog and its Jellyfin integration must be in the same realm.";
    }
    {
      assertion = !degoogModel.rommSelected || (romm != null && romm.enable);
      message = "The selected Degoog RomM integration host must enable RomM.";
    }
    {
      assertion = !degoogModel.rommSelected || (romm != null && romm.publicUrl != null);
      message = "The selected Degoog RomM integration requires a public RomM URL.";
    }
    {
      assertion = !degoogModel.rommSelected || rommHost.host.realm == config.host.realm;
      message = "Degoog and its RomM integration must be in the same realm.";
    }
  ];
}
