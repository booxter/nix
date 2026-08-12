{
  config,
  isDarwin,
  lib,
  ...
}:
let
  cfg = config.host.remote-control.client.x11;
  username = config.host.username;
in
{
  config = lib.mkIf cfg.enable (
    {
      assertions = [
        {
          assertion = config.host.isDesktop;
          message = "host.remote-control.client.x11 requires a desktop host";
        }
      ];

      home-manager.users.${username}.programs.remote-control.client.x11.enable = true;
    }
    // lib.optionalAttrs isDarwin {
      host.userEnvironment.features.gui.x11.enable = true;
    }
  );
}
