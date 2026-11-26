{
  config,
  lib,
  outputs,
}:
let
  cfg = config.host.paperless;
  ssoApplication = config.host.sso.applications.paperless or null;
  accessGroups = if ssoApplication == null then [ ] else builtins.attrValues ssoApplication.roles;
  users = lib.filterAttrs (
    _: user: lib.any (group: builtins.elem group user.groups) accessGroups
  ) config.host.sso.users;
  aiProvider = outputs.nixosConfigurations.${cfg.ai.providerHost}.config or null;
  aiModels =
    if aiProvider == null || aiProvider.host.ollama == null then { } else aiProvider.host.ollama.models;
in
{
  inherit
    accessGroups
    cfg
    aiModels
    aiProvider
    ssoApplication
    users
    ;
  bootstrapOwner = if ssoApplication == null then null else ssoApplication.bootstrapOwner;
  paperlessService = config.host.web.services.paperless;
  metricsInternalPort = 19289;
  metricsMtlsPort = 9348;
  ollamaTunnelPort = 11435;
  storagePath = "/data/paperless";
  passwordSecretName =
    name:
    if ssoApplication != null && name == ssoApplication.bootstrapOwner then
      "paperless/admin/password"
    else
      "paperless/users/${name}/password";
}
