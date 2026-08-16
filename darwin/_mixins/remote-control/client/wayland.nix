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
  config = lib.mkIf (cfg != null) {
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

    home-manager.users.${username} = {
      launchd.agents.cocoa-way = {
        enable = true;
        config = {
          Label = "org.nixos.cocoa-way";
          ProgramArguments = [ "/opt/homebrew/bin/cocoa-way" ];
          EnvironmentVariables = {
            COCOA_WAY_PRESENTATION = "rootless";
            PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
          };
          LimitLoadToSessionType = "Aqua";
          ProcessType = "Interactive";
          StandardOutPath = "/Users/${username}/Library/Logs/nix-darwin/cocoa-way.log";
          StandardErrorPath = "/Users/${username}/Library/Logs/nix-darwin/cocoa-way.log";
          ThrottleInterval = 10;
        };
      };

      programs.remote-control.client.wayland = { };
    };
  };
}
