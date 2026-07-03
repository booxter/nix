{
  inputs,
  lib,
  pkgs,
  stateVersion,
  username,
  hmFull,
  isDarwin,
  isDesktop,
  isWork,
  ...
}:
{
  imports = [
    ./_mixins/nix
    ./_mixins/xquartz
    ./_mixins/zsh
  ]
  ++ lib.optionals hmFull [
    ./_mixins/cli
    ./_mixins/codex
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
    ./_mixins/jankyborders
    ./_mixins/kitty
    ./_mixins/sketchybar
  ]
  ++ lib.optionals (isDesktop && !isDarwin) [
    ./_mixins/hyprland
  ]
  ++ lib.optionals (!isWork && isDesktop) [
    ./_mixins/firefox
  ]
  ++ lib.optionals (hmFull && isWork) [
    ./_mixins/krew
    ./_mixins/nv
  ];

  assertions = [
    {
      assertion = (!isDesktop) || hmFull;
      message = "`isDesktop = true` requires `hmFull = true`.";
    }
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
    ++ lib.optionals (isDesktop && isDarwin) [
      spotify
    ]
    ++ lib.optionals (!isWork && isDesktop && isDarwin) [
      vlc-bin
    ]
    ++ lib.optionals (isDesktop && !isDarwin) [
      wmctrl
      xauth
      xprop
      xwininfo
    ]
    ++ lib.optionals (!isWork && isDesktop && !isDarwin) [
      vlc
    ]
    ++ lib.optionals (!isWork && isDesktop) [
      podman-desktop
    ];
}
