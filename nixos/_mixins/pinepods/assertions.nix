{
  config,
  lib,
  pkgs,
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
    storageGroup
    ;
in
{
  config.assertions = lib.optionals (cfg != null) [
    {
      assertion = claim != null;
      message = "PinePods requires the host's 'media' storage claim";
    }
    {
      assertion = storageGroup != null;
      message = "the PinePods media claim must provide a non-root directory group";
    }
    {
      assertion = ssoApplication != null;
      message = "PinePods requires the realm's 'pinepods' SSO application";
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
  ];
}
