{
  config,
  inputs,
  isDesktop,
  lib,
  username,
  ...
}:
let
  cfg = config.host.remoteGui;
in
{
  options.host.remoteGui = {
    x11.enable = lib.mkEnableOption "X11-forwarded remote Linux applications";
    wayland.enable = lib.mkEnableOption "Cocoa-Way remote Linux applications";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.x11.enable || isDesktop;
          message = "host.remoteGui.x11 requires a desktop host";
        }
        {
          assertion = !cfg.wayland.enable || isDesktop;
          message = "host.remoteGui.wayland requires a desktop host";
        }
      ];
    }
    (lib.mkIf cfg.x11.enable {
      host.xquartz.enable = true;
      home-manager.users.${username}.programs = {
        remoteGui.x11.enable = true;
        xquartz = {
          enable = true;
          configureSsh = true;
        };
      };
    })
    (lib.mkIf cfg.wayland.enable {
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

      # Register the agent without RunAtLoad; wrun-nixpkgs starts it when no
      # live Cocoa-Way socket is available.
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

      home-manager.users.${username}.programs.remoteGui.wayland.enable = true;
    })
  ];
}
