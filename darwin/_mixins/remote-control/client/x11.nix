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
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.host.userEnvironment.roles.workstation.enable;
        message = "host.remote-control.client.x11 requires a managed graphical environment";
      }
    ];

    home-manager.users.${username} = {
      programs.remote-control.client.x11.enable = true;
      host.hm.xquartz.enable = true;
    };
  };
}
