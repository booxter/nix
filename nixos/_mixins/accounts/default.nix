{ config, lib, ... }:
let
  cfg = config.host.accounts;
  uids = map (account: account.uid) (builtins.attrValues cfg.users);
  gids = map (group: group.gid) (builtins.attrValues cfg.groups);
in
{
  options.host.accounts = {
    groups = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.gid = lib.mkOption {
            type = lib.types.ints.positive;
            description = "Numeric group ID shared across hosts.";
          };
        }
      );
      default = { };
      description = "Groups whose numeric identities are stable across hosts.";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            uid = lib.mkOption {
              type = lib.types.ints.positive;
              description = "Numeric user ID shared across hosts.";
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
      description = "Users whose numeric identities are stable across hosts.";
    };
  };

  config = {
    host.accounts = {
      groups = {
        media.gid = 169;
        paperless.gid = 315;
      };

      users = {
        audiobookshelf.uid = 156;
        ebook-converter.uid = 298;
        paperless = {
          uid = 315;
          group = "paperless";
        };
        pinepods.uid = 296;
        romm.uid = 295;
        sabnzbd.uid = 38;
        shelfmark.uid = 250;
        slskd.uid = 297;
        transmission.uid = 70;
      };
    };

    assertions = [
      {
        assertion = builtins.length uids == builtins.length (lib.unique uids);
        message = "host.accounts user UIDs must be unique";
      }
      {
        assertion = builtins.length gids == builtins.length (lib.unique gids);
        message = "host.accounts group GIDs must be unique";
      }
    ]
    ++ lib.mapAttrsToList (name: account: {
      assertion = account.group == null || builtins.hasAttr account.group cfg.groups;
      message = "host.accounts.users.${name} references unknown group '${toString account.group}'";
    }) cfg.users;
  };
}
