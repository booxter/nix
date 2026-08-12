{ config, lib, ... }:
let
  cfg = config.host.sso;
  groupType = lib.types.submodule {
    options.title = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Human-readable SSO group title.";
    };
  };
  userType = lib.types.submodule {
    options = {
      displayName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "SSO display name.";
      };
      legalName = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Legal name provisioned to the identity provider, when declared.";
      };
      mailAddressSopsKey = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "SOPS key containing the user's mail address, when provisioned.";
      };
      groups = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        default = [ ];
        description = "SSO groups assigned to the user.";
      };
    };
  };
  applicationType = lib.types.submodule {
    options = {
      adminGroup = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
      };
      userGroup = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
      };
      editorGroup = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
      };
      viewerGroup = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
      };
      bootstrapOwner = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
      };
      bootstrapLanguage = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "en";
      };
    };
  };
  applicationGroups =
    application:
    builtins.filter (group: group != null) [
      application.adminGroup
      application.userGroup
      application.editorGroup
      application.viewerGroup
    ];
  unknownUserGroups = lib.unique (
    lib.concatMap (user: lib.subtractLists (builtins.attrNames cfg.groups) user.groups) (
      builtins.attrValues cfg.users
    )
  );
  unknownApplicationGroups = lib.unique (
    lib.concatMap (
      application: lib.subtractLists (builtins.attrNames cfg.groups) (applicationGroups application)
    ) (builtins.attrValues cfg.applications)
  );
  unknownBootstrapOwners = lib.unique (
    builtins.filter (owner: owner != null && !builtins.hasAttr owner cfg.users) (
      map (application: application.bootstrapOwner) (builtins.attrValues cfg.applications)
    )
  );
in
{
  imports = [ ./home.nix ];

  options.host.sso = {
    groups = lib.mkOption {
      type = lib.types.attrsOf groupType;
      default = { };
      description = "Groups in this host's SSO realm.";
    };
    users = lib.mkOption {
      type = lib.types.attrsOf userType;
      default = { };
      description = "Users in this host's SSO realm.";
    };
    applications = lib.mkOption {
      type = lib.types.attrsOf applicationType;
      default = { };
      description = "Application ownership and role mappings in this host's SSO realm.";
    };
  };

  config.assertions = [
    {
      assertion = unknownUserGroups == [ ];
      message = "SSO users reference unknown groups: ${lib.concatStringsSep ", " unknownUserGroups}";
    }
    {
      assertion = unknownApplicationGroups == [ ];
      message = "SSO applications reference unknown groups: ${lib.concatStringsSep ", " unknownApplicationGroups}";
    }
    {
      assertion = unknownBootstrapOwners == [ ];
      message = "SSO applications reference unknown bootstrap owners: ${lib.concatStringsSep ", " unknownBootstrapOwners}";
    }
  ];
}
