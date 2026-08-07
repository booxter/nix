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
      rebootMode = config.host.autoUpgrade.rebootMode;
      rebootWindow = upgrade.rebootWindow;
      weeklyReboot = config.systemd.timers.nixos-weekly-reboot-if-needed.timerConfig.OnCalendar or null;
      schedule = if lib.hasInfix " " upgrade.dates then upgrade.dates else "daily ${upgrade.dates}";
      policy =
        if rebootMode == "after-upgrade" then
          "${rebootMode} ${rebootWindow.lower}-${rebootWindow.upper}"
        else if rebootMode == "weekly-if-needed" then
          "${rebootMode} ${weeklyReboot}"
        else
          rebootMode;
    in
    {
      inherit name policy schedule;
      phase = config.host.autoUpgrade.phase;
    };
  rows = map rowFor hostNames;
  maxLength = values: lib.foldl' lib.max 0 (map builtins.stringLength values);
  hostWidth = maxLength ([ "HOST" ] ++ map (row: row.name) rows);
  phaseWidth = maxLength ([ "PHASE" ] ++ map (row: row.phase) rows);
  scheduleWidth = maxLength ([ "UPGRADES" ] ++ map (row: row.schedule) rows);
  policyWidth = maxLength ([ "POLICY" ] ++ map (row: row.policy) rows);
  repeat = count: value: lib.concatStrings (lib.replicate count value);
  pad = width: value: value + repeat (width - builtins.stringLength value) " ";
  renderRow =
    row:
    "${pad hostWidth row.name}  ${pad phaseWidth row.phase}  ${pad scheduleWidth row.schedule}  ${row.policy}";
  table = lib.concatStringsSep "\n" (
    [
      (renderRow {
        name = "HOST";
        phase = "PHASE";
        schedule = "UPGRADES";
        policy = "POLICY";
      })
      (lib.concatStringsSep "  " [
        (repeat hostWidth "-")
        (repeat phaseWidth "-")
        (repeat scheduleWidth "-")
        (repeat policyWidth "-")
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
