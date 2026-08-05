{
  hostSpec,
  lib,
  pkgs,
  username,
  osConfig,
  ...
}:
let
  inherit (osConfig.host) isDarwin isDesktop isWork;
  hmFull = hostSpec.hmFull or true;
  stateVersion = if isDarwin then hostSpec.hmStateVersion else hostSpec.stateVersion;
in
{
  imports = [
    ./_mixins/nix
    ./_mixins/podman-machine
    ./_mixins/resource-control.nix
    ./_mixins/xquartz
    ./_mixins/zsh
  ]
  ++ lib.optionals hmFull [
    ./_mixins/cli
    ./_mixins/remote-gui
    ./_mixins/agents
    ./_mixins/gnupg
    ./_mixins/nixvim
    ./_mixins/podman
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
  ++ lib.optionals isDesktop [
    ./_mixins/spicetify
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
  programs.podman-machine = {
    enable = isDarwin && isDesktop && !isWork;
    provider = "libkrun";
    cpus = 4;
    memoryMiB = 8192;
    diskSizeGiB = 100;
    autoStart = true;
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
    ++ lib.optionals (!isWork && isDesktop) [
      vlc
      podman-desktop
      wmctrl
      xauth
      xprop
      xwininfo
    ];
}
