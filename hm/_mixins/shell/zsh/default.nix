{ ... }:
{
  programs.zsh = {
    enable = true;
    defaultKeymap = "viins";
    enableCompletion = false;

    initContent = ''
      bindkey "^R" history-incremental-search-backward
    '';
  };
}
