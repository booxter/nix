{
  appSpec,
  nixosConfigurations,
  pkgs,
}:
let
  inherit (pkgs) lib;
  hostNames = builtins.attrNames nixosConfigurations;
  rowFor =
    name:
    let
      config = nixosConfigurations.${name}.config;
      upgrade = config.system.autoUpgrade;
      rebootPolicy = config.host.autoUpgrade.rebootPolicy;
      rebootWindow = upgrade.rebootWindow;
      weeklyReboot = config.systemd.timers.nixos-weekly-reboot-if-needed.timerConfig.OnCalendar or null;
      schedule = if lib.hasInfix " " upgrade.dates then upgrade.dates else "daily ${upgrade.dates}";
      renderedRebootPolicy =
        if rebootPolicy == "after-upgrade-if-needed" then
          "${rebootPolicy} ${rebootWindow.lower}-${rebootWindow.upper}"
        else if rebootPolicy == "weekly-if-needed" then
          "${rebootPolicy} ${weeklyReboot}"
        else
          rebootPolicy;
    in
    {
      inherit name renderedRebootPolicy schedule;
      phase = config.host.autoUpgrade.phase;
    };
  rows = map rowFor hostNames;
  maxLength = values: lib.foldl' lib.max 0 (map builtins.stringLength values);
  hostWidth = maxLength ([ "HOST" ] ++ map (row: row.name) rows);
  phaseWidth = maxLength ([ "PHASE" ] ++ map (row: row.phase) rows);
  scheduleWidth = maxLength ([ "UPGRADES" ] ++ map (row: row.schedule) rows);
  rebootPolicyWidth = maxLength ([ "REBOOT POLICY" ] ++ map (row: row.renderedRebootPolicy) rows);
  repeat = count: value: lib.concatStrings (lib.replicate count value);
  pad = width: value: value + repeat (width - builtins.stringLength value) " ";
  renderRow =
    row:
    "${pad hostWidth row.name}  ${pad phaseWidth row.phase}  ${pad scheduleWidth row.schedule}  ${row.renderedRebootPolicy}";
  table = lib.concatStringsSep "\n" (
    [
      (renderRow {
        name = "HOST";
        phase = "PHASE";
        schedule = "UPGRADES";
        renderedRebootPolicy = "REBOOT POLICY";
      })
      (lib.concatStringsSep "  " [
        (repeat hostWidth "-")
        (repeat phaseWidth "-")
        (repeat scheduleWidth "-")
        (repeat rebootPolicyWidth "-")
      ])
    ]
    ++ map renderRow rows
  );
  upgradeShow = pkgs.writeShellApplication {
    name = "upgrade-show";
    text = ''
      printf '%s\n' ${lib.escapeShellArg table}
    '';
  };
in
appSpec (lib.getExe upgradeShow) "Show the evaluated fleet auto-upgrade schedule and reboot policy."
