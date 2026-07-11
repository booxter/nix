{
  lib,
  pkgs,
  isWork,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  codexPkgs = import ../agents/pkgs { inherit pkgs; };
  codexPlugin = pkgs.writeShellApplication {
    name = "sketchybar-codex";
    runtimeInputs = [
      codexPkgs.codex-usage-status
      pkgs.jq
      pkgs.sketchybar
    ];
    text = builtins.readFile ./sketchybar/plugins/codex.sh;
  };
  codexWorkPlugin = pkgs.writeShellApplication {
    name = "sketchybar-codex-work";
    runtimeInputs = [
      codexPkgs.codex-work-usage-status
      pkgs.jq
      pkgs.sketchybar
    ];
    text = builtins.readFile ./sketchybar/plugins/codex-work.sh;
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
                 --set codex.resets script="$PLUGIN_DIR/codex.sh"          \
                                   click_script="sketchybar --set codex.resets popup.drawing=toggle" \
                                   icon.drawing=off                         \
                                   label.padding_left=6                     \
                                   label.padding_right=6                    \
                                   background.border_width=0                \
                                   background.corner_radius=6               \
                                   background.height=24                     \
                                   popup.align=left                         \
                                   popup.background.color="$BACKGROUND_COLOR" \
                                   popup.background.border_color="$BACKGROUND_BORDER_COLOR" \
                                   popup.background.border_width=1           \
                                   popup.background.corner_radius=6          \
                 --subscribe codex.resets mouse.entered mouse.exited        \
                                                                            \
                 --add item codex.resets.expiry popup.codex.resets          \
                 --set codex.resets.expiry updates=off                      \
                                          icon.drawing=off                  \
                                          label.padding_left=8              \
                                          label.padding_right=8             \
                                          background.border_width=0         \
                                          background.height=24
    ''
    + lib.optionalString isWork ''
      sketchybar --add item codex.work left                                 \
                 --set codex.work script="$PLUGIN_DIR/codex-work.sh"        \
                                  update_freq=60                            \
                                  icon.drawing=off                          \
                                  label.padding_left=6                      \
                                  label.padding_right=6                     \
                                  background.border_width=0                 \
                                  background.corner_radius=6                \
                                  background.height=24                      \
                                  popup.align=left                          \
                                  popup.background.color="$BACKGROUND_COLOR" \
                                  popup.background.border_color="$BACKGROUND_BORDER_COLOR" \
                                  popup.background.border_width=1            \
                                  popup.background.corner_radius=6           \
                 --subscribe codex.work system_woke mouse.entered mouse.exited \
                                                                           \
                 --add item codex.work.credits popup.codex.work             \
                 --set codex.work.credits updates=off                       \
                                          icon.drawing=off                  \
                                          label.padding_left=8              \
                                          label.padding_right=8             \
                                          background.border_width=0         \
                                          background.height=24              \
                                                                           \
                 --add item codex.work.reset popup.codex.work               \
                 --set codex.work.reset updates=off                         \
                                        icon.drawing=off                    \
                                        label.padding_left=8                \
                                        label.padding_right=8               \
                                        background.border_width=0           \
                                        background.height=24
    ''
  );
  sketchybarConfig = pkgs.runCommandLocal "sketchybar-config" { } ''
    mkdir -p "$out"
    cp -R ${./sketchybar}/. "$out/"
    chmod -R u+w "$out"
    mkdir -p "$out/items"
    rm -f "$out/plugins/codex.sh"
    rm -f "$out/plugins/codex-work.sh"
    ln -s ${codexItem} "$out/items/codex.sh"
    ${lib.optionalString (!isWork) ''
      ln -s ${lib.getExe codexPlugin} "$out/plugins/codex.sh"
    ''}
    ${lib.optionalString isWork ''
      ln -s ${lib.getExe codexWorkPlugin} "$out/plugins/codex-work.sh"
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
