{
  cfg,
  expectedUnits,
  lib,
  unitLabels,
  units,
}:
[
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
]
