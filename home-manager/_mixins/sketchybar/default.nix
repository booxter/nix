{
  config,
  lib,
  pkgs,
  isWork,
  ...
}:
let
  internalPkiRootCaPath = import ../../../lib/home-internal-pki-root-ca.nix;
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  cliPkgs = import ../cli/pkgs { inherit pkgs; };
  codexPkgs = import ../agents/pkgs { inherit pkgs; };
  workspaceNames = import ../aerospace/workspaces.nix { inherit lib isWork; };
  inherit (config.lib.stylix) colors;
  sketchybarColors = {
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
  pluginColorEnv = {
    SKETCHYBAR_COLOR_NEUTRAL = sketchybarColors.neutral;
    SKETCHYBAR_COLOR_RED = sketchybarColors.red;
    SKETCHYBAR_COLOR_ORANGE = sketchybarColors.orange;
    SKETCHYBAR_COLOR_YELLOW = sketchybarColors.yellow;
    SKETCHYBAR_COLOR_GREEN = sketchybarColors.green;
    SKETCHYBAR_COLOR_BLUE = sketchybarColors.blue;
    SKETCHYBAR_COLOR_PURPLE = sketchybarColors.purple;
  };
  sketchybarTheme = pkgs.writeText "sketchybar-gruvbox-theme" ''
    black="${sketchybarColors.background}"
    blue="${sketchybarColors.blue}"
    blue1="${sketchybarColors.backgroundAlt}"
    cyan="${sketchybarColors.cyan}"
    green="${sketchybarColors.green}"
    magenta="${sketchybarColors.purple}"
    orange="${sketchybarColors.orange}"
    purple="${sketchybarColors.purple}"
    red="${sketchybarColors.red}"
    transparent="0x00000000"
    white="${sketchybarColors.neutral}"
    yellow="${sketchybarColors.yellow}"

    BAR_COLOR="$black"
    BAR_BLUR_RADIUS=0
    BAR_POSITION="top"
    BAR_HEIGHT=30
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
  codexPlugin = pkgs.writeShellApplication {
    name = "sketchybar-codex";
    runtimeInputs = [
      codexPkgs.codex-usage-status
      pkgs.jq
      pkgs.sketchybar
    ];
    runtimeEnv = pluginColorEnv;
    text = builtins.readFile ./sketchybar/plugins/codex.sh;
  };
  codexWorkPlugin = pkgs.writeShellApplication {
    name = "sketchybar-codex-work";
    runtimeInputs = [
      codexPkgs.codex-work-usage-status
      pkgs.jq
      pkgs.sketchybar
    ];
    runtimeEnv = pluginColorEnv;
    text = builtins.readFile ./sketchybar/plugins/codex-work.sh;
  };
  alertmanagerPlugin = pkgs.writeShellApplication {
    name = "sketchybar-alertmanager";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.sketchybar
    ];
    runtimeEnv = pluginColorEnv // {
      ALERTMANAGER_URL = config.programs.sketchybarAlertmanager.alertmanagerUrl;
      ALERTMANAGER_CA_CERTIFICATE = toString internalPkiRootCaPath;
      ALERTMANAGER_CLIENT_CERTIFICATE = config.programs.sketchybarAlertmanager.clientCertificate;
      ALERTMANAGER_CLIENT_KEY = config.programs.sketchybarAlertmanager.clientKey;
    };
    text = builtins.readFile ./sketchybar/plugins/alertmanager.sh;
  };
  jellyfinPlugin = pkgs.writeShellApplication {
    name = "sketchybar-jellyfin";
    runtimeInputs = [
      pkgs.curl
      pkgs.gawk
      pkgs.sketchybar
    ];
    runtimeEnv = pluginColorEnv // {
      JELLYFIN_METRICS_URL = config.programs.sketchybarJellyfin.metricsUrl;
      JELLYFIN_CA_CERTIFICATE = toString internalPkiRootCaPath;
      JELLYFIN_CLIENT_CERTIFICATE = config.programs.sketchybarJellyfin.clientCertificate;
      JELLYFIN_CLIENT_KEY = config.programs.sketchybarJellyfin.clientKey;
    };
    text = builtins.readFile ./sketchybar/plugins/jellyfin.sh;
  };
  attentionInboxPlugin = pkgs.writeShellApplication {
    name = "sketchybar-attention-inbox";
    runtimeInputs = [
      cliPkgs.attention-inbox
      pkgs.jq
      pkgs.sketchybar
    ];
    runtimeEnv = pluginColorEnv;
    text = builtins.readFile ./sketchybar/plugins/attention-inbox.sh;
  };
  githubStatusPlugin = pkgs.writeShellApplication {
    name = "sketchybar-github-status";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.sketchybar
    ];
    runtimeEnv = pluginColorEnv // {
      GITHUB_STATUS_URL = "https://www.githubstatus.com/api/v2/summary.json";
    };
    text = builtins.readFile ./sketchybar/plugins/github-status.sh;
  };
  stockPlugin = pkgs.writeShellApplication {
    name = "sketchybar-stock";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.sketchybar
    ];
    runtimeEnv = pluginColorEnv;
    text = builtins.readFile ./sketchybar/plugins/stock.sh;
  };
  diskPlugin = pkgs.writeShellApplication {
    name = "sketchybar-disk";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.sketchybar
    ];
    text = builtins.readFile ./sketchybar/plugins/disk.sh;
  };
  diskItem = pkgs.writeText "sketchybar-disk-item.sh" ''
    sketchybar --add item disk left                              \
               --set disk script="$PLUGIN_DIR/disk.sh"          \
                          update_freq=60                         \
                          icon.drawing=off                       \
               --subscribe disk system_woke
  '';
  githubStatusItem = pkgs.writeText "sketchybar-github-status-item.sh" ''
    sketchybar --add item github-status right                           \
               --set github-status script="$PLUGIN_DIR/github-status.sh" \
                                   update_freq=60                       \
                                   drawing=off                          \
                                   icon=""                            \
                                   icon.font="JetBrainsMono Nerd Font:Regular:16.0" \
                                   icon.color="${sketchybarColors.red}" \
                                   icon.padding_left=6                  \
                                   icon.padding_right=6                 \
                                   label.drawing=off                    \
                                   click_script="/usr/bin/open https://www.githubstatus.com" \
               --subscribe github-status system_woke
  '';
  alertmanagerItem = pkgs.writeText "sketchybar-alertmanager-item.sh" (
    lib.optionalString config.programs.sketchybarAlertmanager.enable ''
      sketchybar --add item alertmanager right                               \
                 --set alertmanager script="$PLUGIN_DIR/alertmanager.sh"     \
                                    update_freq=60                           \
                                    drawing=off                              \
                                    icon.padding_left=6                      \
                                    icon.padding_right=2                     \
                                    label.padding_left=2                     \
                                    label.padding_right=6                    \
                                    click_script="/usr/bin/open ${lib.escapeShellArg config.programs.sketchybarAlertmanager.grafanaUrl}"                                       \
                 --subscribe alertmanager system_woke
    ''
  );
  jellyfinItem = pkgs.writeText "sketchybar-jellyfin-item.sh" (
    lib.optionalString config.programs.sketchybarJellyfin.enable ''
      sketchybar --add item jellyfin right                              \
                 --set jellyfin script="$PLUGIN_DIR/jellyfin.sh"       \
                                update_freq=30                          \
                                drawing=off                             \
                                icon="󰼁"                               \
                                icon.font="JetBrainsMono Nerd Font:Regular:16.0" \
                                icon.color="${sketchybarColors.purple}" \
                                icon.padding_left=6                     \
                                icon.padding_right=2                    \
                                label.padding_left=2                    \
                                label.padding_right=6                   \
                                click_script="/usr/bin/open ${lib.escapeShellArg config.programs.sketchybarJellyfin.dashboardUrl}" \
                 --subscribe jellyfin system_woke
    ''
  );
  attentionInboxItem = pkgs.writeText "sketchybar-attention-inbox-item.sh" (
    lib.optionalString isWork ''
      sketchybar --add item attention.inbox right                                \
                 --set attention.inbox script="$PLUGIN_DIR/attention-inbox.sh"   \
                                       update_freq=1200                          \
                                       drawing=off                               \
                                       icon.drawing=off                          \
                                       icon.padding_left=6                       \
                                       icon.padding_right=2                      \
                                       label.padding_left=2                      \
                                       label.padding_right=6                     \
                                       click_script="sketchybar --set attention.inbox popup.drawing=toggle" \
                                       popup.align=right                         \
                                       popup.background.color="$BACKGROUND_COLOR" \
                                       popup.background.border_color="$BACKGROUND_BORDER_COLOR" \
                                       popup.background.border_width=1           \
                                       popup.background.corner_radius=6          \
                 --subscribe attention.inbox system_woke

      for index in {0..9}; do
        sketchybar --add item "attention.inbox.$index" popup.attention.inbox     \
                   --set "attention.inbox.$index" updates=off                    \
                                                    drawing=off                   \
                                                    icon.drawing=off              \
                                                    icon.padding_left=8           \
                                                    icon.padding_right=4          \
                                                    label.align=left              \
                                                    label.padding_left=8          \
                                                    label.padding_right=8         \
                                                    background.border_width=0     \
                                                    background.height=24
      done
    ''
  );
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
  aerospaceSpacesItem = pkgs.writeText "sketchybar-aerospace-spaces.sh" (
    ''
      sketchybar --add event aerospace_workspace_change
    ''
    + lib.concatMapStringsSep "\n" (
      sid:
      let
        escapedSid = lib.escapeShellArg sid;
      in
      ''
        sketchybar --add item space.${sid} left \
            --subscribe space.${sid} aerospace_workspace_change \
            --set space.${sid} \
            background.color=0x44${colors.base05} \
            background.corner_radius=5 \
            background.height=25 \
            background.drawing=off \
            label="${sid}" \
            click_script="aerospace workspace ${escapedSid}" \
            script="$CONFIG_DIR/plugins/aerospace.sh ${escapedSid}"
      ''
    ) workspaceNames
  );
  sketchybarConfig = pkgs.runCommandLocal "sketchybar-config" { } ''
    mkdir -p "$out"
    cp -R ${./sketchybar}/. "$out/"
    chmod -R u+w "$out"
    rm -rf "$out/themes"
    mkdir -p "$out/themes"
    ln -s ${sketchybarTheme} "$out/themes/gruvbox"
    mkdir -p "$out/items"
    rm -f "$out/plugins/codex.sh"
    rm -f "$out/plugins/codex-work.sh"
    rm -f "$out/plugins/alertmanager.sh"
    rm -f "$out/plugins/jellyfin.sh"
    rm -f "$out/plugins/attention-inbox.sh"
    rm -f "$out/plugins/github-status.sh"
    rm -f "$out/plugins/disk.sh"
    rm -f "$out/plugins/stock.sh"
    rm -f "$out/items/aerospace-spaces.sh"
    rm -f "$out/items/disk.sh"
    rm -f "$out/items/alertmanager.sh"
    rm -f "$out/items/jellyfin.sh"
    rm -f "$out/items/attention-inbox.sh"
    rm -f "$out/items/github-status.sh"
    ln -s ${aerospaceSpacesItem} "$out/items/aerospace-spaces.sh"
    ln -s ${diskItem} "$out/items/disk.sh"
    ln -s ${codexItem} "$out/items/codex.sh"
    ln -s ${alertmanagerItem} "$out/items/alertmanager.sh"
    ln -s ${jellyfinItem} "$out/items/jellyfin.sh"
    ln -s ${attentionInboxItem} "$out/items/attention-inbox.sh"
    ln -s ${githubStatusItem} "$out/items/github-status.sh"
    ln -s ${lib.getExe diskPlugin} "$out/plugins/disk.sh"
    ln -s ${lib.getExe githubStatusPlugin} "$out/plugins/github-status.sh"
    ln -s ${lib.getExe stockPlugin} "$out/plugins/stock.sh"
    ${lib.optionalString config.programs.sketchybarAlertmanager.enable ''
      ln -s ${lib.getExe alertmanagerPlugin} "$out/plugins/alertmanager.sh"
    ''}
    ${lib.optionalString config.programs.sketchybarJellyfin.enable ''
      ln -s ${lib.getExe jellyfinPlugin} "$out/plugins/jellyfin.sh"
    ''}
    ${lib.optionalString (!isWork) ''
      ln -s ${lib.getExe codexPlugin} "$out/plugins/codex.sh"
    ''}
    ${lib.optionalString isWork ''
      ln -s ${lib.getExe codexWorkPlugin} "$out/plugins/codex-work.sh"
      ln -s ${lib.getExe attentionInboxPlugin} "$out/plugins/attention-inbox.sh"
    ''}
  '';
in
{
  options.programs.sketchybarAlertmanager = {
    enable = lib.mkEnableOption "Alertmanager firing-alert indicator in SketchyBar";

    alertmanagerUrl = lib.mkOption {
      type = lib.types.str;
      description = "mTLS-protected Alertmanager alerts API URL.";
    };

    grafanaUrl = lib.mkOption {
      type = lib.types.str;
      description = "Grafana alert groups page opened when the indicator is clicked.";
    };

    clientCertificate = lib.mkOption {
      type = lib.types.str;
      description = "Path to the Alertmanager mTLS client certificate.";
    };

    clientKey = lib.mkOption {
      type = lib.types.str;
      description = "Path to the Alertmanager mTLS client key.";
    };
  };

  options.programs.sketchybarJellyfin = {
    enable = lib.mkEnableOption "active Jellyfin stream indicator in SketchyBar";

    metricsUrl = lib.mkOption {
      type = lib.types.str;
      description = "mTLS-protected Jellyfin exporter metrics URL.";
    };

    dashboardUrl = lib.mkOption {
      type = lib.types.str;
      description = "Grafana media dashboard opened when the indicator is clicked.";
    };

    clientCertificate = lib.mkOption {
      type = lib.types.str;
      description = "Path to the Jellyfin exporter mTLS client certificate.";
    };

    clientKey = lib.mkOption {
      type = lib.types.str;
      description = "Path to the Jellyfin exporter mTLS client key.";
    };
  };

  config.programs.sketchybar = lib.mkIf isDarwin {
    enable = true;
    config = {
      source = sketchybarConfig;
      recursive = true;
    };
    # Let launchd own the process lifetime. Aerospace only sends workspace events.
    service.enable = true;
    extraPackages = with pkgs; [
      aerospace
      gnugrep
      curl
      jq
    ];
  };
}
