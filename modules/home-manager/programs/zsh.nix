{ pkgs, ... }: {
  enable = true;
  autosuggestion = {
    enable = true;
    strategy = [ "match_prev_cmd" "completion" ];
  };
  syntaxHighlighting.enable = true;
  initExtra = ''
      eval "$(/opt/homebrew/bin/brew shellenv)"
      set -o vi
      bindkey "^R" history-incremental-search-backward
  '';
  shellAliases = {
    ls = "ls --color=auto -F";
    chatgpt = "OPENAI_API_KEY=$(${pkgs.pass}/bin/pass priv/openai-chatgpt-secret) chatgpt";
    sgpt = "OPENAI_API_KEY=$(${pkgs.pass}/bin/pass priv/openai-chatgpt-secret) sgpt";
  };
}
