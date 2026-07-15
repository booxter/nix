{
  config,
  lib,
  pkgs,
  isWork,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
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
      ALERTMANAGER_CLIENT_CERTIFICATE = config.programs.sketchybarAlertmanager.clientCertificate;
      ALERTMANAGER_CLIENT_KEY = config.programs.sketchybarAlertmanager.clientKey;
    };
    text = builtins.readFile ./sketchybar/plugins/alertmanager.sh;
  };
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
    rm -f "$out/items/aerospace-spaces.sh"
    rm -f "$out/items/alertmanager.sh"
    ln -s ${aerospaceSpacesItem} "$out/items/aerospace-spaces.sh"
    ln -s ${codexItem} "$out/items/codex.sh"
    ln -s ${alertmanagerItem} "$out/items/alertmanager.sh"
    ${lib.optionalString config.programs.sketchybarAlertmanager.enable ''
      ln -s ${lib.getExe alertmanagerPlugin} "$out/plugins/alertmanager.sh"
    ''}
    ${lib.optionalString (!isWork) ''
      ln -s ${lib.getExe codexPlugin} "$out/plugins/codex.sh"
    ''}
    ${lib.optionalString isWork ''
      ln -s ${lib.getExe codexWorkPlugin} "$out/plugins/codex-work.sh"
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
