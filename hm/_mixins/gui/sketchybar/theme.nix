{
  config,
  height,
  pkgs,
}:
let
  inherit (config.lib.stylix) colors;
  palette = {
    background = "0xff${colors.base00}";
    backgroundAlt = "0xff${colors.base01}";
    neutral = "0xff${colors.base05}";
    red = "0xff${colors.base08}";
    orange = "0xff${colors.base09}";
    yellow = "0xff${colors.base0A}";
    green = "0xff${colors.base0B}";
    cyan = "0xff${colors.base0C}";
    blue = "0xff${colors.base0D}";
    purple = "0xff${colors.base0E}";
  };
in
{
  pluginEnvironment = {
    SKETCHYBAR_COLOR_NEUTRAL = palette.neutral;
    SKETCHYBAR_COLOR_RED = palette.red;
    SKETCHYBAR_COLOR_ORANGE = palette.orange;
    SKETCHYBAR_COLOR_YELLOW = palette.yellow;
    SKETCHYBAR_COLOR_GREEN = palette.green;
    SKETCHYBAR_COLOR_BLUE = palette.blue;
    SKETCHYBAR_COLOR_PURPLE = palette.purple;
  };

  file = pkgs.writeText "sketchybar-gruvbox-theme" ''
    black="${palette.background}"
    blue="${palette.blue}"
    blue1="${palette.backgroundAlt}"
    cyan="${palette.cyan}"
    green="${palette.green}"
    magenta="${palette.purple}"
    orange="${palette.orange}"
    purple="${palette.purple}"
    red="${palette.red}"
    transparent="0x00000000"
    white="${palette.neutral}"
    yellow="${palette.yellow}"

    BAR_COLOR="$black"
    BAR_BLUR_RADIUS=0
    BAR_POSITION="top"
    BAR_HEIGHT=${toString height}
    BAR_PADDING=0
    BAR_Y_OFFSET=0
    BAR_CORNER_RADIUS=0
    BAR_MARGIN=0

    BACKGROUND_COLOR="$blue1"
    BACKGROUND_BORDER_COLOR="$blue"
    BACKGROUND_BORDER_WIDTH=0
    LABEL_ALIGN="center"
    LABEL_COLOR="$blue"
    LABEL_HIGHLIGHT_COLOR="$red"

    ICON_BASE_FONT="SF Pro"
    ICON_FONT="$ICON_BASE_FONT:Bold:14.0"
    LABEL_BASE_FONT="${config.stylix.fonts.monospace.name}"
    LABEL_FONT="$LABEL_BASE_FONT:Regular:14.0"
    LABEL_HIGHLIGHT_FONT="$LABEL_BASE_FONT:ExtraBold:14.0"

    BACKGROUND_CORNER_RADIUS=4
    BACKGROUND_HEIGHT=24
    LABEL_Y_OFFSET=1
    LABEL_PADDING=6
    BRACKET_BACKGROUND_BORDER_WIDTH=2
    BRACKET_BACKGROUND_CORNER_RADIUS=12
  '';
}
