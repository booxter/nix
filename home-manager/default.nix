{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
  isDesktop,
  isPrivate,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin;
in
{
  imports =
    [
      inputs.nixvim.homeManagerModules.nixvim
      ./_mixins/cli-tools
      ./_mixins/nixvim
      ./_mixins/scm
      ./_mixins/scripts
      ./_mixins/ssh
      ./_mixins/tmux
      ./_mixins/git-sync
    ]
    ++ lib.optionals isDesktop [
      ./_mixins/copy-apps
      ./_mixins/email
      ./_mixins/fonts
      ./_mixins/ide
      ./_mixins/kitty
      ./_mixins/spotify
    ] ++ lib.optionals (isDesktop && isPrivate) [
      ./_mixins/firefox
      ./_mixins/ollama
      ./_mixins/telegram
      ./_mixins/x11
    ] ++ lib.optionals (!isPrivate) [
      ./_mixins/nv
    ];

  home = {
    inherit stateVersion;
    inherit username;
    homeDirectory = if isDarwin then "/Users/${username}" else "/home/${username}";
  };

  systemd.user = lib.optionalAttrs (!isDarwin) {
    enable = true;
    startServices = true;
  };

  nixpkgs = {
    overlays = [
      inputs.nur.overlays.default
      outputs.overlays.additions
      outputs.overlays.modifications
      outputs.overlays.unstable-packages
      outputs.overlays.master-packages
    ];
    config = {
      allowUnfree = true;
    };
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
    ]
    ++ lib.optionals isDarwin [
      keycastr
      stats
    ];

  # TODO: move darwin specific config files to a separate module?
  home.file = lib.optionalAttrs isDarwin {
    ".amethyst.yml".source = ./dotfiles/amethyst.yml;
  };
}
