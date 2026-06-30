{
  lib,
  pkgs,
  isWork,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  codexPkgs = import ../codex/pkgs { inherit pkgs; };
  codexPlugin = pkgs.writeShellApplication {
    name = "sketchybar-codex";
    runtimeInputs = [
      codexPkgs.codex-usage-status
      pkgs.jq
      pkgs.sketchybar
    ];
    text = builtins.readFile ./sketchybar/plugins/codex.sh;
  };
  codexItem = pkgs.writeText "sketchybar-codex-items.sh" (
    lib.optionalString (!isWork) ''
      sketchybar --add item codex.5h left                                  \
                 --set codex.5h script="$PLUGIN_DIR/codex.sh"             \
                                update_freq=60                             \
                                icon.drawing=off                           \
                                label.padding_left=6                       \
                                label.padding_right=6                      \
                                background.border_width=0                  \
                                background.corner_radius=6                 \
                                background.height=24                       \
                 --subscribe codex.5h system_woke                         \
                                                                            \
                 --add item codex.weekly left                              \
                 --set codex.weekly updates=off                            \
                                    icon.drawing=off                        \
                                    label.padding_left=6                    \
                                    label.padding_right=6                   \
                                    background.border_width=0               \
                                    background.corner_radius=6              \
                                    background.height=24                    \
                                                                            \
                 --add item codex.resets left                              \
                 --set codex.resets updates=off                            \
                                   icon.drawing=off                         \
                                   label.padding_left=6                     \
                                   label.padding_right=6                    \
                                   background.border_width=0                \
                                   background.corner_radius=6               \
                                   background.height=24
    ''
  );
  sketchybarConfig = pkgs.runCommandLocal "sketchybar-config" { } ''
    mkdir -p "$out"
    cp -R ${./sketchybar}/. "$out/"
    chmod -R u+w "$out"
    mkdir -p "$out/items"
    rm -f "$out/plugins/codex.sh"
    ln -s ${codexItem} "$out/items/codex.sh"
    ${lib.optionalString (!isWork) ''
      ln -s ${lib.getExe codexPlugin} "$out/plugins/codex.sh"
    ''}
  '';
in
{
  programs.sketchybar = lib.mkIf isDarwin {
    enable = true;
    config = {
      source = sketchybarConfig;
      recursive = true;
    };
    service.enable = false;
    extraPackages = with pkgs; [
      aerospace
      gnugrep
      curl
      jq
    ];
  };
}
