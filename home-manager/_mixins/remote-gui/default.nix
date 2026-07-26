{
  config,
  isDarwin,
  isDesktop,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.remoteGui;
  remoteGuiPkgs = import ./pkgs { inherit pkgs; };
in
{
  options.programs.remoteGui = {
    x11.enable = lib.mkOption {
      type = lib.types.bool;
      default = isDesktop && (!isDarwin || config.programs.xquartz.enable);
      defaultText = lib.literalExpression "isDesktop && (!isDarwin || config.programs.xquartz.enable)";
      description = "Whether to install the X11 remote nixpkgs runner.";
    };

    wayland.enable = lib.mkEnableOption "the Cocoa-Way remote nixpkgs runner";
  };

  config = {
    assertions = lib.optional cfg.wayland.enable {
      assertion = isDarwin && isDesktop;
      message = "programs.remoteGui.wayland requires a Darwin desktop host";
    };

    home.packages =
      lib.optionals cfg.x11.enable [ remoteGuiPkgs.xrun-nixpkgs ]
      ++ lib.optionals cfg.wayland.enable [ remoteGuiPkgs.wrun-nixpkgs ];
  };
}
