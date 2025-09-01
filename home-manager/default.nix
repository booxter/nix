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
    ./_mixins/nixvim
    ./_mixins/scm
    ./_mixins/ssh
    ./_mixins/tmux
    ./_mixins/git-sync
    ./_mixins/ide-headless
  ]
  ++ lib.optionals isDesktop [
    ./_mixins/aerospace
    ./_mixins/jankyborders
    ./_mixins/sketchybar

    ./_mixins/copy-apps
    ./_mixins/email
    ./_mixins/fonts
    ./_mixins/ide
    ./_mixins/kitty
    ./_mixins/spotify
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

  home.packages =
    with pkgs;
    [
    ]
    ++ lib.optionals isDesktop [
      obsidian
      podman-desktop
      wireshark
      zoom-us
      telegram-desktop
    ]
    ++ lib.optionals isDarwin [
      keycastr
    ];
}
