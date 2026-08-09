{ lib }:
let
  inherit (import ./lib.nix { inherit lib; }) mkAlert mkGroup;
in
{
  groups = [
    (mkGroup {
      name = "systemd";
      rules = [
        (mkAlert {
          name = "ExpectedSystemdUnitInactive";
          expr = ''
            (
              nixos_systemd_unit_expected_active{scrape_profile="node"} == 1
              unless on(instance, name)
              node_systemd_unit_state{scrape_profile="node",state="active"} == 1
            )
            and on(instance)
            up{scrape_profile="node"} == 1
          '';
          for = "5m";
          severity = "warning";
          category = "systemd";
          summary = "Systemd unit inactive: {{ $labels.name }} on {{ $labels.instance }}";
          description = "NixOS expects {{ $labels.name }} to remain active on {{ $labels.instance }}, but systemd has not reported it active for 5 minutes.";
        })
        (mkAlert {
          name = "SystemdUnitFailed";
          expr = ''node_systemd_unit_state{scrape_profile="node",state="failed"} == 1'';
          for = "5m";
          severity = "warning";
          category = "systemd";
          summary = "Systemd unit failed: {{ $labels.name }} on {{ $labels.instance }}";
          description = "The systemd unit {{ $labels.name }} on {{ $labels.instance }} has remained failed for 5 minutes.";
        })
      ];
    })
  ];
}
