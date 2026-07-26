{
  config,
  inputs,
  isDesktop,
  lib,
  username,
  ...
}:
let
  cfg = config.host.remoteGui.wayland;
in
{
  options.host.remoteGui.wayland.enable = lib.mkEnableOption "Cocoa-Way remote Linux applications";

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isDesktop;
        message = "host.remoteGui.wayland requires a desktop host";
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

    home-manager.users.${username}.programs.remoteGui.wayland.enable = true;
  };
}
