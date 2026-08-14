{
  outputs,
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;
  hostNames = builtins.attrNames outputs.nixosConfigurations;
  rowFor =
    name:
    let
      config = outputs.nixosConfigurations.${name}.config;
      autoUpgrade = config.host.autoUpgrade;
      activeClaims = lib.filterAttrs (
        claimName: claim:
        claimName != "baseline"
        && (
          claim.switch.cadence != null
          || claim.reboot.cadence != null
          || claim.availabilityGroup != null
          || claim.exclusions != [ ]
        )
      ) autoUpgrade.claims;
      rebootTimer = config.systemd.timers.nixos-reboot-if-needed or null;
      reboot =
        if config.system.autoUpgrade.allowReboot then
          "with switch"
        else if rebootTimer == null then
          "never"
        else
          rebootTimer.timerConfig.OnCalendar;
    in
    {
      inherit name reboot;
      inherit (config.host) realm;
      claims =
        if activeClaims == { } then
          "baseline"
        else
          lib.concatStringsSep "," (builtins.attrNames activeClaims);
      switch = config.system.autoUpgrade.dates;
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
      value = row: row.switch;
    }
    {
      heading = "REBOOT";
      value = row: row.reboot;
    }
    {
      heading = "CLAIMS";
      value = row: row.claims;
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
  package = pkgs.writeShellApplication {
    name = "upgrade-show";
    text = ''
      printf '%s\n' ${lib.escapeShellArg table}
    '';
  };
in
{
  inherit package;
  description = "Show the evaluated fleet auto-upgrade plan and contributing claims.";
}
