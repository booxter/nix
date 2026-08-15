{
  lib,
  rommModel,
  ...
}:
let
  model = rommModel;
  inherit (model) cfg ssoApplication;
in
{
  config = lib.mkIf (cfg != null) {
    assertions = [
      {
        assertion = model.claim != null;
        message = "RomM requires the media storage claim";
      }
      {
        assertion = model.storageGroup != null;
        message = "The selected RomM storage claim must provide a shared group";
      }
      {
        assertion = model.identity != null;
        message = "RomM requires its shared storage identity";
      }
      {
        assertion = ssoApplication != null;
        message = "RomM requires its realm SSO application";
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
