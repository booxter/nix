{
  config,
  lib,
  ...
}:
let
  cfg = config.host.remote-control.client.x11;
  username = config.host.username;
in
{
  config = lib.mkIf (cfg != null) {
    home-manager.users.${username} = {
      programs.remote-control.client.x11 = { };
      host.hm.xquartz.enable = true;
    };
  };
}
