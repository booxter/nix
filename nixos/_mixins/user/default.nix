{ username, ... }:
{
  security.loginDefs.settings = {
    LOGIN_TIMEOUT = 180; # 3 minutes until login timeout (default: 60)
  };

  users.mutableUsers = false;
  users.users.${username} = {
    extraGroups = [
      "wheel"
      "users"
    ];
    group = username;
    isNormalUser = true;
  };
  users.groups.${username} = { };
}
