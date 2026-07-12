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
    ./_mixins/agents
    ./_mixins/gnupg
    ./_mixins/nixvim
    ./_mixins/scm
    ./_mixins/ssh
    ./_mixins/tmux
    ./_mixins/yubi.nix
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
  programs.xquartz = lib.mkIf (isDarwin && isDesktop && !isWork) {
    enable = true;
    configureSsh = true;
  };
  targets.darwin.copyApps.enable = isDarwin; # populate apps dir for Spotlight

  home.packages =
    let
      vlc = if isDarwin then pkgs.vlc-bin else pkgs.vlc;
    in
    with pkgs;
    [
    ]
    ++ lib.optionals isDesktop [
      element-desktop
      obsidian
      telegram-desktop
      wireshark
    ]
    ++ lib.optionals (isDesktop && isDarwin) [
      spotify
    ]
    ++ lib.optionals (!isWork && isDesktop) [
      vlc
      podman-desktop
      wmctrl
      xauth
      xprop
      xwininfo
    ];
}
