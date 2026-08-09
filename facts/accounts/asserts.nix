{ lib }:
raw:
let
  uids = map (account: account.uid) (builtins.attrValues raw.users);
  gids = map (group: group.gid) (builtins.attrValues raw.groups);
in
[
  {
    assertion = builtins.length uids == builtins.length (lib.unique uids);
    message = "shared account UIDs must be unique";
  }
  {
    assertion = builtins.length gids == builtins.length (lib.unique gids);
    message = "shared account GIDs must be unique";
  }
]
