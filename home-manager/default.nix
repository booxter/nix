{
  config,
  inputs,
  lib,
  outputs,
  pkgs,
  stateVersion,
  username,
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
    ./_mixins/default-apps
    ./_mixins/email
    ./_mixins/firefox
    ./_mixins/fonts
    ./_mixins/git-sync
    ./_mixins/kitty
    ./_mixins/nixvim
    ./_mixins/scm
    ./_mixins/scripts
    ./_mixins/spotify
    ./_mixins/ssh
    ./_mixins/telegram
    ./_mixins/tmux
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

  programs.home-manager.enable = true; # let it manage itself

  home.packages =
    with pkgs;
    [
      discord
      obsidian
      podman-desktop
      wireshark
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

  home.sessionVariables = {
    HOMEBREW_NO_AUTO_UPDATE = 1; # can I move it to darwin?
  };

  # set all session variables for launchd services
  launchd.agents.launchctl-setenv = lib.optionalAttrs isDarwin (
    let launchctl-setenv = pkgs.writeShellScriptBin "launchctl-setenv"
      (lib.concatStringsSep "\n" (lib.mapAttrsToList
        (name: val: "/bin/launchctl setenv ${name} ${toString val}")
        config.home.sessionVariables));
    in {
      enable = true;
      config = {
        ProgramArguments = [ "${launchctl-setenv}/bin/launchctl-setenv" ];
        KeepAlive.SuccessfulExit = false;
        RunAtLoad = true;
      };
    }
  );

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
