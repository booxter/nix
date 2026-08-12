{
  config,
  lib,
  outputs,
}:
let
  cfg = config.host.paperless;
  ssoApplication = config.host.sso.applications.${cfg.sso.application} or null;
  accessGroups =
    if ssoApplication == null then
      [ ]
    else
      builtins.filter (group: group != null) [
        ssoApplication.adminGroup
        ssoApplication.userGroup
      ];
  users = lib.filterAttrs (
    _: user: lib.any (group: builtins.elem group user.groups) accessGroups
  ) config.host.sso.users;
  gptProviderHost = cfg.gpt.ollama.providerHost;
  gptProvider =
    if gptProviderHost == null then
      null
    else
      outputs.nixosConfigurations.${gptProviderHost}.config or null;
  gptModels = if gptProvider == null then { } else gptProvider.host.ollama.models;
  storagePath = cfg.storage.mountPoint;
in
{
  inherit
    accessGroups
    cfg
    gptModels
    gptProvider
    ssoApplication
    storagePath
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
  passwordSecretName =
    name:
    if ssoApplication != null && name == ssoApplication.bootstrapOwner then
      "paperless/admin/password"
    else
      "paperless/users/${name}/password";
}
