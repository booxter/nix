{
  downloadCapacityMbit,
  downloadersMaxMbit,
  lib,
  pkgs,
  uploadCapacityMbit,
}:
let
  sourceDirectory = ./dashboards;
  mbitToBits = value: builtins.floor (value * 1000 * 1000);
  referenceLabel = value: "${toString value} Mbit Reference";
  downloadCapacityBits = mbitToBits downloadCapacityMbit;
  downloadersMaxBits = mbitToBits downloadersMaxMbit;
  uploadCapacityBits = mbitToBits uploadCapacityMbit;
  uploadWarningBits = builtins.floor (uploadCapacityBits * 0.75);

  patchTargets =
    references:
    map (
      target:
      let
        rateMbit = references.${target.refId or ""} or null;
      in
      if rateMbit == null then
        target
      else
        target
        // {
          expr = "vector(${toString (mbitToBits rateMbit)})";
          legendFormat = referenceLabel rateMbit;
        }
    );

  patchOverrides =
    labels:
    map (
      override:
      let
        currentLabel = override.matcher.options or null;
        replacement = labels.${currentLabel} or null;
      in
      if replacement == null then
        override
      else
        override
        // {
          matcher = override.matcher // {
            options = replacement;
          };
        }
    );

  patchPanel =
    panel:
    if panel.title == "WAN Inbound Bandwidth (Stacked)" then
      panel
      // {
        fieldConfig = panel.fieldConfig // {
          defaults = panel.fieldConfig.defaults // {
            softMax = downloadCapacityBits;
            thresholds = {
              mode = "absolute";
              steps = [
                {
                  color = "green";
                  value = null;
                }
                {
                  color = "orange";
                  value = downloadersMaxBits;
                }
                {
                  color = "red";
                  value = downloadCapacityBits;
                }
              ];
            };
          };
          overrides = patchOverrides {
            "400 Mbit Reference" = referenceLabel downloadersMaxMbit;
            "1000 Mbit Reference" = referenceLabel downloadCapacityMbit;
          } panel.fieldConfig.overrides;
        };
        targets = patchTargets {
          B = downloadersMaxMbit;
          C = downloadCapacityMbit;
        } panel.targets;
      }
    else if panel.title == "WAN Outbound Bandwidth (Stacked)" then
      panel
      // {
        fieldConfig = panel.fieldConfig // {
          defaults = panel.fieldConfig.defaults // {
            softMax = uploadCapacityBits;
            thresholds = {
              mode = "absolute";
              steps = [
                {
                  color = "green";
                  value = null;
                }
                {
                  color = "orange";
                  value = uploadWarningBits;
                }
                {
                  color = "red";
                  value = uploadCapacityBits;
                }
              ];
            };
          };
          overrides = patchOverrides {
            "40 Mbit Reference" = referenceLabel uploadCapacityMbit;
          } panel.fieldConfig.overrides;
        };
        targets = patchTargets { B = uploadCapacityMbit; } panel.targets;
      }
    else
      panel;

  patchedDashboardNames = [
    "media-pipe.json"
    "network-overview.json"
  ];
  dashboardFiles = lib.filterAttrs (_: type: type == "regular") (builtins.readDir sourceDirectory);
  dashboardPath =
    name:
    if builtins.elem name patchedDashboardNames then
      let
        dashboard = builtins.fromJSON (builtins.readFile (sourceDirectory + "/${name}"));
        rendered = dashboard // {
          panels = map patchPanel dashboard.panels;
        };
      in
      pkgs.writeText name "${builtins.toJSON rendered}\n"
    else
      sourceDirectory + "/${name}";
in
pkgs.linkFarm "fana-grafana-dashboards" (
  lib.mapAttrsToList (name: _: {
    inherit name;
    path = dashboardPath name;
  }) dashboardFiles
)
