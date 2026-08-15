{ config, lib, ... }:
let
  cfg = config.host.sso;
  userType = lib.types.submodule {
    options = {
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
      roles = lib.mkOption {
        type = with lib.types; attrsOf nonEmptyStr;
        default = { };
      };
      bootstrapOwner = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
      };
    };
  };
  unknownUserGroups = lib.unique (
    lib.concatMap (user: lib.subtractLists cfg.groups user.groups) (builtins.attrValues cfg.users)
  );
  unknownApplicationGroups = lib.unique (
    lib.concatMap (application: lib.subtractLists cfg.groups (builtins.attrValues application.roles)) (
      builtins.attrValues cfg.applications
    )
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
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
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
