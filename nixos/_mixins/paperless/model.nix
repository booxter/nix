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
  gptProviderHost = if cfg == null || cfg.gpt == null then null else cfg.gpt.providerHost;
  gptProvider =
    if gptProviderHost == null then
      null
    else
      outputs.nixosConfigurations.${gptProviderHost}.config or null;
  gptModels =
    if gptProvider == null || gptProvider.host.ollama == null then
      { }
    else
      gptProvider.host.ollama.models;
in
{
  inherit
    accessGroups
    cfg
    gptModels
    gptProvider
    ssoApplication
    users
    ;
  bootstrapOwner = if ssoApplication == null then null else ssoApplication.bootstrapOwner;
  paperlessService = config.host.web.services.paperless;
  gptStateDir = "/var/lib/paperless-gpt";
  gptPort = 8080;
  gptOauth2ProxyPort = 4181;
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
