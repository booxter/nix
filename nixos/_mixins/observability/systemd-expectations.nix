{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability;
  textfileDir = cfg.nodeExporter.textfile.directory;

  withSuffix =
    suffix: units:
    lib.mapAttrs' (
      name: unit:
      lib.nameValuePair (if lib.hasSuffix ".${suffix}" name then name else "${name}.${suffix}") unit
    ) units;

  units =
    withSuffix "service" config.systemd.services
    // withSuffix "timer" config.systemd.timers
    // withSuffix "socket" config.systemd.sockets
    // withSuffix "path" config.systemd.paths
    // withSuffix "target" config.systemd.targets;

  activationLinks =
    unit: (unit.wantedBy or [ ]) ++ (unit.requiredBy or [ ]) ++ (unit.upheldBy or [ ]);
  dependencies = unit: (unit.wants or [ ]) ++ (unit.requires or [ ]) ++ (unit.upholds or [ ]);
  roots = lib.mapAttrsToList (name: _: { key = name; }) (
    lib.filterAttrs (_: unit: activationLinks unit != [ ]) units
  );
  activatedUnits = lib.genericClosure {
    startSet = roots;
    operator =
      item:
      map (name: { key = name; }) (
        builtins.filter (name: builtins.hasAttr name units) (dependencies units.${item.key})
      );
  };
  activatedNames = map (item: item.key) activatedUnits;

  isPersistentService =
    name:
    let
      service = units.${name};
      type = service.serviceConfig.Type or null;
      remainAfterExit = service.serviceConfig.RemainAfterExit or false;
      hasLocalImplementation =
        (service.script or "") != "" || (service.serviceConfig.ExecStart or null) != null;
    in
    hasLocalImplementation
    && (
      type != "oneshot"
      || builtins.elem remainAfterExit [
        true
        "yes"
      ]
    );
  isExpected =
    name:
    lib.hasSuffix ".timer" name
    || lib.hasSuffix ".socket" name
    || lib.hasSuffix ".path" name
    || (lib.hasSuffix ".service" name && isPersistentService name);
  expectedUnits = builtins.sort builtins.lessThan (builtins.filter isExpected activatedNames);

  escapeLabel = value: lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] value;
  metricsFile = pkgs.writeText "systemd-unit-expectations.prom" (
    ''
      # HELP nixos_systemd_unit_expected_active Whether NixOS expects a persistent systemd unit to be active.
      # TYPE nixos_systemd_unit_expected_active gauge
    ''
    + lib.concatMapStrings (name: ''
      nixos_systemd_unit_expected_active{name="${escapeLabel name}"} 1
    '') expectedUnits
  );
in
{
  config = lib.mkIf cfg.enable {
    host.observability.nodeExporter.textfile.enable = true;

    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root - -"
      "L+ ${textfileDir}/systemd-unit-expectations.prom - - - - ${metricsFile}"
    ];
  };
}
