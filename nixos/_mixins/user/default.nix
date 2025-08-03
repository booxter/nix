{ username, ... }:
{
  users.mutableUsers = false;
  users.users.${username} = {
    extraGroups = ["wheel" "users"];
    group = username;
    isNormalUser = true;
  };
  users.groups.${username} = {};
}
