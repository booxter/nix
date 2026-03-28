{ ... }:
{
  programs.zsh = {
    enable = true;
    defaultKeymap = "viins";
    enableCompletion = false;

    initContent = ''
      bindkey "^R" history-incremental-search-backward

      iftop() {
        local primary_iface

        primary_iface="$(
          ip -o route show to default 2>/dev/null \
            | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
        )"

        if [[ -n "$primary_iface" ]]; then
          sudo iftop -b -N -P -o 40s -i "$primary_iface" "$@"
        else
          sudo iftop -b -N -P -o 40s "$@"
        fi
      }
    '';

    shellAliases = {
      # Beautify ls output.
      ll = "ls --hyperlink=auto --color=auto -Fal";
      ls = "ls --hyperlink=auto --color=auto -F";

      view = "vim -R";
    };
  };
}
