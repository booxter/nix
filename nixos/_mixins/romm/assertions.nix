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
      lib
      pkgs
      storageModel
      ;
  };
  inherit (model) cfg ssoApplication;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.publicHostName != null;
        message = "host.romm.publicHostName must be set";
      }
      {
        assertion = model.claim != null;
        message = "host.romm.storage.claim must select a known storage claim";
      }
      {
        assertion = model.storageGroup != null;
        message = "The selected RomM storage claim must provide a shared group";
      }
      {
        assertion = model.identity != null;
        message = "host.romm.user must select a shared storage identity";
      }
      {
        assertion = ssoApplication != null;
        message = "host.romm.sso.application must select a realm SSO application";
      }
      {
        assertion =
          ssoApplication != null
          && ssoApplication.roles ? admin
          && ssoApplication.roles ? editor
          && ssoApplication.roles ? viewer
          && ssoApplication.bootstrapOwner != null;
        message = "The RomM SSO application must define administrator, editor, viewer, and bootstrap-owner roles";
      }
      {
        assertion =
          ssoApplication == null
          || ssoApplication.bootstrapOwner == null
          || builtins.attrNames model.admins == [ ssoApplication.bootstrapOwner ];
        message = "The RomM bootstrap owner must be its only SSO administrator";
      }
      {
        assertion = lib.all (person: builtins.length (model.groupsFor person) == 1) (
          builtins.attrValues model.authorizedUsers
        );
        message = "Each RomM SSO user must belong to exactly one RomM access group";
      }
    ];
  };
}
