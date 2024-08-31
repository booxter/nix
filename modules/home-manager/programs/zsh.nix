{ pkgs, ... }: {
  enable = true;
  autosuggestion = {
    enable = true;
    strategy = [ "match_prev_cmd" "completion" ];
  };
  syntaxHighlighting.enable = true;
  defaultKeymap = "viins";
  initExtra = ''
      eval "$(/opt/homebrew/bin/brew shellenv)"
      bindkey "^R" history-incremental-search-backward
  '';
  shellAliases = {
    ll = "ls --hyperlink=auto --color=auto -Fal";
    ls = "ls --hyperlink=auto --color=auto -F";
    chatgpt = "OPENAI_API_KEY=$(${pkgs.pass}/bin/pass priv/openai-chatgpt-secret) chatgpt";
    sgpt = "OPENAI_API_KEY=$(${pkgs.pass}/bin/pass priv/openai-chatgpt-secret) sgpt";
    rg = "rg --hyperlink-format=kitty";
    icat = "kitten icat";
    q = "eza";
    qq = "eza -l";
  };
}
