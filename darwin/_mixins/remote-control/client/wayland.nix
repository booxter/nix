{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.host.remote-control.client.wayland;
  username = config.host.username;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.host.userEnvironment.roles.workstation.enable;
        message = "host.remote-control.client.wayland requires a managed graphical environment";
      }
    ];

    homebrew.brews = [
      "cocoa-way"
      "waypipe-darwin"
    ];
    nix-homebrew = {
      taps."J-x-Z/homebrew-tap" = inputs.cocoa-way-homebrew-tap;
      trust.formulae = [
        "J-x-Z/tap/cocoa-way"
        "J-x-Z/tap/waypipe-darwin"
      ];
    };

    launchd.user.agents.cocoa-way.serviceConfig = {
      Label = "org.nixos.cocoa-way";
      ProgramArguments = [ "/opt/homebrew/bin/cocoa-way" ];
      EnvironmentVariables = {
        COCOA_WAY_PRESENTATION = "rootless";
        PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      LimitLoadToSessionType = "Aqua";
      ProcessType = "Interactive";
      StandardOutPath = "/Users/${username}/Library/Logs/cocoa-way.log";
      StandardErrorPath = "/Users/${username}/Library/Logs/cocoa-way.log";
      ThrottleInterval = 10;
    };

    home-manager.users.${username}.programs.remote-control.client.wayland.enable = true;
  };
}
