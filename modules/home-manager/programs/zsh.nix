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
  shellAliases = let
    gcalcliHome = "gcalcli --config-folder ~/.gcalcli --calendar Home";
    gcalcliWork = "gcalcli --config-folder ~/.gcalcli-rh --calendar ihrachys@redhat.com";
    gcalcliCalwArgs = "calw --military --nodeclined --monday";
  in {
    ll = "ls --hyperlink=auto --color=auto -Fal";
    ls = "ls --hyperlink=auto --color=auto -F";
    chatgpt = "OPENAI_API_KEY=$(${pkgs.pass}/bin/pass priv/openai-chatgpt-secret) chatgpt";
    sgpt = "OPENAI_API_KEY=$(${pkgs.pass}/bin/pass priv/openai-chatgpt-secret) sgpt";
    rg = "rg --hyperlink-format=kitty";
    icat = "kitten icat";
    q = "eza";
    qq = "eza -l";
    gmailctl-rh="gmailctl --config=$HOME/.gmailctl-rh";
    view="nvim -R";
    gc="${gcalcliHome}";
    gc-rh="${gcalcliWork}";
    gcw="${gcalcliHome} ${gcalcliCalwArgs}";
    gcw-rh="${gcalcliWork} ${gcalcliCalwArgs}";
  };
}
