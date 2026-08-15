{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability;
  textfileDir = cfg.nodeExporter.textfile.directories.default;
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
  isEnabled = unit: unit.enable or true;
  roots = lib.mapAttrsToList (name: _: { key = name; }) (
    lib.filterAttrs (_: unit: isEnabled unit && activationLinks unit != [ ]) units
  );
  activatedUnits = lib.genericClosure {
    startSet = roots;
    operator =
      item:
      map (name: { key = name; }) (
        builtins.filter (name: builtins.hasAttr name units && isEnabled units.${name}) (
          dependencies units.${item.key}
        )
      );
  };
  activatedNames = map (item: item.key) activatedUnits;
  isStopWhenUnneeded =
    name:
    builtins.elem (units.${name}.unitConfig.StopWhenUnneeded or false) [
      true
      "yes"
    ];
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
    !builtins.elem name cfg.systemd.excludedUnits
    && !isStopWhenUnneeded name
    && (
      lib.hasSuffix ".timer" name
      || lib.hasSuffix ".socket" name
      || lib.hasSuffix ".path" name
      || (lib.hasSuffix ".service" name && isPersistentService name)
    );
  expectedUnits = builtins.sort builtins.lessThan (builtins.filter isExpected activatedNames);
  unitLabels = cfg.systemd.unitLabels;
  escapeLabel = value: lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" "\\n" ] value;
  formatLabels =
    name:
    lib.concatStringsSep "," (
      lib.mapAttrsToList (label: value: ''${label}="${escapeLabel value}"'') (
        { inherit name; } // (unitLabels.${name} or { })
      )
    );
  metricsFile = pkgs.writeText "systemd-unit-expectations.prom" (
    ''
      # HELP nixos_systemd_unit_expected_active Whether NixOS expects a persistent systemd unit to be active.
      # TYPE nixos_systemd_unit_expected_active gauge
    ''
    + lib.concatMapStrings (name: ''
      nixos_systemd_unit_expected_active{${formatLabels name}} 1
    '') expectedUnits
  );
in
{
  options.host.observability.systemd = {
    excludedUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Systemd units excluded from expected-active monitoring.";
    };

    unitLabels = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = { };
      description = "Prometheus labels attached to expected systemd units.";
    };
  };

  config = lib.mkIf cfg.enable {
    # This unit runs only while switching configurations. Inspecting its
    # unitConfig also recurses through the tmpfiles rules generated below.
    host.observability.systemd.excludedUnits = [ "systemd-tmpfiles-resetup.service" ];

    assertions = [
      {
        assertion = lib.all (labels: !(labels ? name)) (builtins.attrValues unitLabels);
        message = "host.observability.systemd.unitLabels must not override the unit name label";
      }
      {
        assertion = lib.all (name: builtins.elem name expectedUnits) (builtins.attrNames unitLabels);
        message = "host.observability.systemd.unitLabels may only label expected active units";
      }
      {
        assertion = lib.all (name: builtins.hasAttr name units) cfg.systemd.excludedUnits;
        message = "host.observability.systemd.excludedUnits may only name defined systemd units";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${textfileDir} 0755 root root - -"
      "L+ ${textfileDir}/systemd-unit-expectations.prom - - - - ${metricsFile}"
    ];
  };
}
