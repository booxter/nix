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

      home-manager.users.${username}.programs.remoteGui.wayland.enable = true;
    })
  ];
}
