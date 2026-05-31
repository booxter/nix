{
  config,
  lib,
  pkgs,
  isWork,
  username,
  ...
}:
let
  managePasswordSecrets = !isWork;
  rootPasswordSecret = "users/root/hashedPassword";
  userPasswordSecret = "users/${username}/hashedPassword";
in
{
  security.loginDefs.settings = {
    LOGIN_TIMEOUT = 180; # 3 minutes until login timeout (default: 60)
  };

  sops.secrets = lib.mkIf managePasswordSecrets {
    "${rootPasswordSecret}".neededForUsers = true;
    "${userPasswordSecret}".neededForUsers = true;
  };

  users.mutableUsers = false;
  users.defaultUserShell = pkgs.zsh;
  users.users.root = lib.mkIf managePasswordSecrets {
    hashedPasswordFile = config.sops.secrets.${rootPasswordSecret}.path;
  };
  users.users.${username} = {
    extraGroups = [
      "wheel"
      "users"
    ];
    group = username;
    isNormalUser = true;
  }
  // lib.optionalAttrs managePasswordSecrets {
    hashedPasswordFile = config.sops.secrets.${userPasswordSecret}.path;
  };
  users.groups.${username} = { };
}
