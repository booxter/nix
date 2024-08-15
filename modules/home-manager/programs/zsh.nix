{
  enable = true;
  autosuggestion = {
    enable = true;
    strategy = [ "match_prev_cmd" "completion" ];
  };
  syntaxHighlighting.enable = true;
  initExtra = ''
      eval "$(/opt/homebrew/bin/brew shellenv)"
  '';
  shellAliases = { ls = "ls --color=auto -F"; };
}