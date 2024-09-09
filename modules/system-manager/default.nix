{ config, lib, pkgs, username, ... }:
{
  config = {
    nixpkgs.hostPlatform = "x86_64-linux";

    users.users.${username} = {
      name = username;
      home = "/home/${username}";
    };
  };
}
