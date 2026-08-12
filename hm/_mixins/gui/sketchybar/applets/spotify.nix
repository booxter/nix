{ config, lib, ... }:
let
  cfg = config.host.hm.sketchybar.spotify;
  inherit (import ./lib.nix { inherit lib; }) mkAppletOptions;
in
{
  options.host.hm.sketchybar.spotify = mkAppletOptions {
    description = "Spotify playback controls";
    defaultPosition = "left";
    defaultOrder = 500;
  };

  assertions = [
    {
      assertion = !cfg.enable || config.host.hm.spotify.enable;
      message = "host.hm.sketchybar.spotify requires host.hm.spotify.";
    }
  ];

  config.host.hm.sketchybar.internal.applets.spotify = lib.mkIf cfg.enable {
    inherit (cfg) position order;
    plugins = [ "spotify" ];
    # Original source: https://github.com/nicolas-martin/awesome-sketchybar/blob/master/plugins/Spotify-Player-Controls.md
    script = ''
      SPOTIFY_EVENT="com.spotify.client.PlaybackStateChanged"
      POPUP_SCRIPT="sketchybar -m --set \$NAME popup.drawing=toggle"

      sketchybar --add event spotify_change "$SPOTIFY_EVENT" \
                 --add item spotify.name ${cfg.position} \
                 --set spotify.name click_script="$POPUP_SCRIPT" \
                                    popup.horizontal=on \
                                    popup.align=center \
                                    icon.drawing=off \
                                    label.max_chars=20 \
                                    scroll_texts=on \
                 --add item spotify.back popup.spotify.name \
                 --set spotify.back icon=􀊎 \
                                    icon.padding_left=5 \
                                    icon.padding_right=5 \
                                    script="$PLUGIN_DIR/spotify.sh" \
                                    label.drawing=off \
                 --subscribe spotify.back mouse.clicked \
                 --add item spotify.play popup.spotify.name \
                 --set spotify.play icon=􀊔 \
                                    icon.padding_left=5 \
                                    icon.padding_right=5 \
                                    updates=on \
                                    label.drawing=off \
                                    script="$PLUGIN_DIR/spotify.sh" \
                 --subscribe spotify.play mouse.clicked spotify_change \
                 --add item spotify.next popup.spotify.name \
                 --set spotify.next icon=􀊐 \
                                    icon.padding_left=5 \
                                    icon.padding_right=10 \
                                    label.drawing=off \
                                    script="$PLUGIN_DIR/spotify.sh" \
                 --subscribe spotify.next mouse.clicked \
                 --add item spotify.shuffle popup.spotify.name \
                 --set spotify.shuffle icon=􀊝 \
                                       icon.highlight_color="$GREEN" \
                                       icon.padding_left=5 \
                                       icon.padding_right=5 \
                                       label.drawing=off \
                                       script="$PLUGIN_DIR/spotify.sh" \
                 --subscribe spotify.shuffle mouse.clicked \
                 --add item spotify.repeat popup.spotify.name \
                 --set spotify.repeat icon=􀊞 \
                                      icon.highlight_color="$GREEN" \
                                      icon.padding_left=5 \
                                      icon.padding_right=5 \
                                      label.drawing=off \
                                      script="$PLUGIN_DIR/spotify.sh" \
                 --subscribe spotify.repeat mouse.clicked
    '';
  };
}
