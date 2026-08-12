{ lib, osConfig, ... }:
lib.mkIf osConfig.host.userEnvironment.features.shell.enable {
  programs.zsh = {
    enable = true;
    defaultKeymap = "viins";
    enableCompletion = false;

    initContent = ''
      bindkey "^R" history-incremental-search-backward
    '';
  };
}
