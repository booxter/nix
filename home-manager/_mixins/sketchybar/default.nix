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
  alertmanagerPlugin = pkgs.writeShellApplication {
    name = "sketchybar-alertmanager";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.sketchybar
    ];
    runtimeEnv = {
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
    runtimeEnv = {
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
    text = builtins.readFile ./sketchybar/plugins/attention-inbox.sh;
  };
  githubStatusPlugin = pkgs.writeShellApplication {
    name = "sketchybar-github-status";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.sketchybar
    ];
    runtimeEnv.GITHUB_STATUS_URL = "https://www.githubstatus.com/api/v2/summary.json";
    text = builtins.readFile ./sketchybar/plugins/github-status.sh;
  };
  githubStatusItem = pkgs.writeText "sketchybar-github-status-item.sh" ''
    sketchybar --add item github-status right                           \
               --set github-status script="$PLUGIN_DIR/github-status.sh" \
                                   update_freq=60                       \
                                   drawing=off                          \
                                   icon=""                            \
                                   icon.font="JetBrainsMono Nerd Font:Regular:16.0" \
                                   icon.color="0xfff7768e"              \
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
                                icon.color="0xffaa5cc3"                 \
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
            background.color=0x44ffffff \
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
    mkdir -p "$out/items"
    rm -f "$out/plugins/codex.sh"
    rm -f "$out/plugins/codex-work.sh"
    rm -f "$out/plugins/alertmanager.sh"
    rm -f "$out/plugins/jellyfin.sh"
    rm -f "$out/plugins/attention-inbox.sh"
    rm -f "$out/plugins/github-status.sh"
    rm -f "$out/items/aerospace-spaces.sh"
    rm -f "$out/items/alertmanager.sh"
    rm -f "$out/items/jellyfin.sh"
    rm -f "$out/items/attention-inbox.sh"
    rm -f "$out/items/github-status.sh"
    ln -s ${aerospaceSpacesItem} "$out/items/aerospace-spaces.sh"
    ln -s ${codexItem} "$out/items/codex.sh"
    ln -s ${alertmanagerItem} "$out/items/alertmanager.sh"
    ln -s ${jellyfinItem} "$out/items/jellyfin.sh"
    ln -s ${attentionInboxItem} "$out/items/attention-inbox.sh"
    ln -s ${githubStatusItem} "$out/items/github-status.sh"
    ln -s ${lib.getExe githubStatusPlugin} "$out/plugins/github-status.sh"
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
