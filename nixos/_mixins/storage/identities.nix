{ config, lib, ... }:
let
  cfg = config.host.storage.identities;
  uids = map (identity: identity.uid) (builtins.attrValues cfg.users);
  gids = builtins.attrValues cfg.groups;
in
{
  options.host.storage.identities = {
    groups = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = { };
      description = "Groups whose numeric identities are shared across storage boundaries.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            uid = lib.mkOption {
              type = lib.types.ints.positive;
              description = "Numeric user ID shared across storage boundaries.";
            };

            group = lib.mkOption {
              type = lib.types.nullOr lib.types.nonEmptyStr;
              default = null;
              description = "Shared primary group, when managed with the user.";
            };
          };
        }
      );
      default = { };
      description = "Users whose numeric identities are shared across storage boundaries.";
    };
  };

  config = {
    host.storage.identities = {
      groups = {
        media = 169;
        paperless = 315;
      };

      users = {
        paperless = {
          uid = 315;
          group = "paperless";
        };
        pinepods.uid = 296;
        romm.uid = 295;
        sabnzbd.uid = 38;
        slskd.uid = 297;
        transmission.uid = 70;
      };
    };

    assertions = [
      {
        assertion = builtins.length uids == builtins.length (lib.unique uids);
        message = "host.storage.identities user UIDs must be unique";
      }
      {
        assertion = builtins.length gids == builtins.length (lib.unique gids);
        message = "host.storage.identities group GIDs must be unique";
      }
    ]
    ++ lib.mapAttrsToList (name: identity: {
      assertion = identity.group == null || builtins.hasAttr identity.group cfg.groups;
      message = "host.storage.identities.users.${name} references unknown group '${toString identity.group}'";
    }) cfg.users;
  };
}
