{
  config,
  lib,
  pkgs,
  storageIdentities,
  storageModel,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      pkgs
      storageModel
      ;
  };
  inherit (model)
    bootstrapOwner
    cfg
    claim
    ssoApplication
    ;
in
{
  config.assertions = lib.optionals cfg.enable [
    {
      assertion = cfg.publicHostName != null;
      message = "host.pinepods.publicHostName must be set";
    }
    {
      assertion = claim != null;
      message = "host.pinepods.storage.claim must name a host storage claim";
    }
    {
      assertion = model.storageGroup != null;
      message = "host.pinepods.storage.claim must provide a non-root directory group";
    }
    {
      assertion = ssoApplication != null;
      message = "host.pinepods.sso.application must select a realm SSO application";
    }
    {
      assertion = ssoApplication != null && ssoApplication.roles ? admin;
      message = "the PinePods SSO application must define an admin group";
    }
    {
      assertion = ssoApplication != null && ssoApplication.roles ? user;
      message = "the PinePods SSO application must define a user group";
    }
    {
      assertion = bootstrapOwner != null;
      message = "the PinePods SSO application must select a bootstrap owner";
    }
    {
      assertion = bootstrapOwner != null && bootstrapOwner.mailAddressSopsKey != null;
      message = "the PinePods bootstrap owner must provide a realm mail-address secret";
    }
    {
      assertion =
        bootstrapOwner != null
        && ssoApplication != null
        && builtins.elem ssoApplication.roles.admin bootstrapOwner.groups;
      message = "the PinePods bootstrap owner must belong to its SSO admin group";
    }
    {
      assertion =
        bootstrapOwner != null
        && ssoApplication != null
        && builtins.elem ssoApplication.roles.user bootstrapOwner.groups;
      message = "the PinePods bootstrap owner must belong to its SSO user group";
    }
    {
      assertion = cfg.integrations.searchApi.url != null;
      message = "host.pinepods.integrations.searchApi.url must be set";
    }
    {
      assertion = cfg.integrations.podPeople.url != null;
      message = "host.pinepods.integrations.podPeople.url must be set";
    }
    {
      assertion = builtins.hasAttr cfg.user storageIdentities.users;
      message = "host.pinepods.user must select a shared storage identity";
    }
  ];
}
