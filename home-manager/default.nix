{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
  isLaptop,
  ...
}:
let
  inherit (pkgs.stdenv) isDarwin;
in
{
  imports = [
    inputs.nixvim.homeManagerModules.nixvim
    ./_mixins/awscli
    ./_mixins/cli-tools
    ./_mixins/git-sync
    ./_mixins/nixvim
    ./_mixins/scm
    ./_mixins/scripts
    ./_mixins/ssh
    ./_mixins/tmux
  ] ++ lib.optionals isLaptop [
    ./_mixins/default-apps
    ./_mixins/email
    ./_mixins/kitty
    ./_mixins/firefox
    ./_mixins/fonts
    ./_mixins/spotify
    ./_mixins/telegram
    ./_mixins/vscode
  ];

  home = {
    inherit stateVersion;
    inherit username;
    homeDirectory = if isDarwin then "/Users/${username}" else "/home/${username}";
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

  services.ollama.enable = true;
  launchd.agents.ollama = lib.optionalAttrs isDarwin {
    config = {
      StandardErrorPath = "/tmp/ollama.err";
      StandardOutPath = "/tmp/ollama.out";
    };
  };

  programs.home-manager.enable = true; # let it manage itself

  home.packages =
    with pkgs;
    [
    ] ++ lib.optionals isLaptop [
      discord
      obsidian
      podman-desktop
      wireshark
      zoom-us
    ]
    ++ lib.optionals isDarwin [
      cb_thunderlink-native
      element-desktop
      iterm2
      keycastr
      raycast
      slack
      homerow
    ];

  # TODO: move darwin specific config files to a separate module?
  home.file = lib.optionalAttrs isDarwin {
    ".config/svim/blacklist".source = ./dotfiles/svim-blacklist;
    ".iterm2/com.googlecode.iterm2.plist".source = ./dotfiles/iterm2.plist;
    ".amethyst.yml".source = ./dotfiles/amethyst.yml;

    # TODO: replace with skhd shortcut
    ".bin/terminal-new-window.sh" = {
      executable = true;
      text = ''
        #!${lib.getExe pkgs.zsh}
        #
        # Required parameters:
        # @raycast.schemaVersion 1
        # @raycast.title Terminal New Window
        # @raycast.mode silent

        # Optional parameters:
        # @raycast.icon 🤖

        # Documentation:
        # @raycast.description Create new window in preferred Terminal
        # @raycast.author Ihar Hrachyshka

        # --single-instance doesn't play well with amethyst (it doesn't recognize consequent windows)
        ${lib.getExe pkgs.kitty} --directory ~ > /dev/null 2>&1
      '';
    };
  };
}
