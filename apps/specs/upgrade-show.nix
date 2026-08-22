{
  autoUpgradeEvaluation,
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;
  inherit (autoUpgradeEvaluation)
    calculatedSchedules
    claimsByHost
    committedSchedules
    errors
    nixosHosts
    ;
  hostNames = lib.unique (autoUpgradeEvaluation.hostNames ++ builtins.attrNames committedSchedules);
  renderReboot =
    schedule:
    if schedule == null then
      "-"
    else if schedule.reboot.mode == "with-upgrade" then
      "with switch"
    else if schedule.reboot.mode == "never" then
      "never"
    else
      schedule.reboot.calendar;
  rowFor =
    name:
    let
      committed = committedSchedules.${name} or null;
      calculated = calculatedSchedules.${name} or null;
      claims = claimsByHost.${name} or { };
      activeClaims = lib.filterAttrs (
        claimName: claim:
        claimName != "baseline"
        && (
          claim.switch.cadence != null
          || claim.reboot.cadence != null
          || claim.availabilityGroup != null
          || claim.exclusions != [ ]
        )
      ) claims;
    in
    {
      inherit name;
      realm = if builtins.hasAttr name nixosHosts then nixosHosts.${name}.realm else "-";
      committedSwitch = if committed == null then "-" else committed.switch;
      calculatedSwitch = if calculated == null then "-" else calculated.switch;
      committedReboot = renderReboot committed;
      calculatedReboot = renderReboot calculated;
      claims =
        if activeClaims == { } then
          "baseline"
        else
          lib.concatStringsSep "," (builtins.attrNames activeClaims);
      status =
        if committed == null then
          "missing"
        else if calculated == null then
          "unknown"
        else if committed != calculated then
          "drifted"
        else
          "current";
    };
  rows = map rowFor hostNames;
  columns = [
    {
      heading = "HOST";
      value = row: row.name;
    }
    {
      heading = "REALM";
      value = row: row.realm;
    }
    {
      heading = "SWITCH";
      value = row: row.committedSwitch;
    }
    {
      heading = "CALCULATED SWITCH";
      value = row: row.calculatedSwitch;
    }
    {
      heading = "REBOOT";
      value = row: row.committedReboot;
    }
    {
      heading = "CALCULATED REBOOT";
      value = row: row.calculatedReboot;
    }
    {
      heading = "CLAIMS";
      value = row: row.claims;
    }
    {
      heading = "STATUS";
      value = row: row.status;
    }
  ];
  maxLength = values: lib.foldl' lib.max 0 (map builtins.stringLength values);
  widthFor = column: maxLength ([ column.heading ] ++ map column.value rows);
  repeat = count: value: lib.concatStrings (lib.replicate count value);
  pad = width: value: value + repeat (width - builtins.stringLength value) " ";
  renderValues =
    values:
    lib.concatStringsSep "  " (
      lib.imap0 (
        index: value:
        if index + 1 == builtins.length values then
          value
        else
          pad (widthFor (builtins.elemAt columns index)) value
      ) values
    );
  header = renderValues (map (column: column.heading) columns);
  separator = lib.concatStringsSep "  " (map (column: repeat (widthFor column) "-") columns);
  renderRow = row: renderValues (map (column: column.value row) columns);
  table = lib.concatStringsSep "\n" (
    [
      header
      separator
    ]
    ++ map renderRow rows
  );
  errorText = lib.concatStringsSep "\n" errors;
  package = pkgs.writeShellApplication {
    name = "upgrade-show";
    text = ''
      printf '%s\n' ${lib.escapeShellArg table}
      ${lib.optionalString (errors != [ ]) ''
        printf '\n%s\n' ${lib.escapeShellArg errorText} >&2
        exit 1
      ''}
    '';
  };
in
{
  inherit package;
  description = "Check and show the committed fleet auto-upgrade plan.";
}
