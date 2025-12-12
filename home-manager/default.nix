{
  inputs,
  lib,
  pkgs,
  stateVersion,
  username,
  isDesktop,
  isWork,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin;
in
{
  imports = [
    ../common/_mixins/nix
  ]
  ++ [
    ./_mixins/cli-tools
    ./_mixins/git-sync
    ./_mixins/gnupg
    ./_mixins/ide-headless
    ./_mixins/nixvim
    ./_mixins/scm
    ./_mixins/ssh
    ./_mixins/tmux
  ]
  ++ lib.optionals isDesktop [
    ./_mixins/aerospace
    ./_mixins/email
    ./_mixins/fonts
    ./_mixins/hyprland
    ./_mixins/jankyborders
    ./_mixins/kitty
    ./_mixins/sketchybar
  ]
  ++ lib.optionals (!isWork && isDesktop) [
    ./_mixins/firefox
  ]
  ++ lib.optionals isWork [
    ./_mixins/krew
    ./_mixins/nv
  ];

  nixpkgs.overlays = [
    inputs.nur.overlays.default
  ];

  home = {
    inherit stateVersion;
    inherit username;
    homeDirectory = if isDarwin then "/Users/${username}" else "/home/${username}";
  };

  programs.home-manager.enable = true; # let it manage itself
  targets.darwin.copyApps.enable = isDarwin; # populate apps dir for Spotlight

  home.packages =
    with pkgs;
    [
    ]
    ++ lib.optionals isDesktop [
      obsidian
      telegram-desktop
      wireshark
    ]
    ++ lib.optionals (!isWork && isDesktop) [
      podman-desktop
    ];
}
