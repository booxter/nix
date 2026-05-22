{ lib, pkgs, ... }:
let
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  diskBayMappings = [
    {
      bay = "1";
      row = "1";
      col = "1";
      serial = "ZYD01W48";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "3";
      row = "3";
      col = "1";
      serial = "ZYD0CASB";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "5";
      row = "5";
      col = "1";
      serial = "ZYD05Z4J";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "6";
      row = "1";
      col = "2";
      serial = "ZYD041CP";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "7";
      row = "2";
      col = "2";
      serial = "ZXA0RKFF";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "9";
      row = "4";
      col = "2";
      serial = "ZXA0B5K4";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "10";
      row = "5";
      col = "2";
      serial = "ZXA0FFNN";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "11";
      row = "1";
      col = "3";
      serial = "ZYD01W92";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "12";
      row = "2";
      col = "3";
      serial = "ZXA0GW38";
      model = "ST24000NM000C-3WD103";
    }
    {
      bay = "13";
      row = "3";
      col = "3";
      serial = "ZYD02EQQ";
      model = "ST24000NM000H-3KS103";
    }
    {
      bay = "15";
      row = "5";
      col = "3";
      serial = "ZXA0ENE4";
      model = "ST24000NM000C-3WD103";
    }
  ];
  diskBayExporter = pkgs.writeShellScript "beast-disk-bay-export" ''
    set -euo pipefail

    mkdir -p ${textfileDir}
    tmp_file="$(mktemp ${textfileDir}/disk-bays.prom.XXXXXX)"
    trap 'rm -f "$tmp_file"' EXIT

    cat > "$tmp_file" <<'EOF'
    # HELP host_observability_disk_bay_info Current mapping of beast disk device names to physical bays.
    # TYPE host_observability_disk_bay_info gauge
    EOF

    ${lib.concatMapStringsSep "\n" (mapping: ''
      device="$(${pkgs.util-linux}/bin/lsblk -dn -o NAME,SERIAL | ${pkgs.gawk}/bin/awk '$2 == "${mapping.serial}" { print $1; exit }')"
      if [ -n "$device" ]; then
        printf 'host_observability_disk_bay_info{device="%s",bay="${mapping.bay}",bay_row="${mapping.row}",bay_col="${mapping.col}",serial="${mapping.serial}",model="${mapping.model}"} 1\n' "$device" >> "$tmp_file"
      fi
    '') diskBayMappings}

    chmod 0644 "$tmp_file"
    mv "$tmp_file" ${textfileDir}/disk-bays.prom
    trap - EXIT
  '';
in
{
  environment.etc."beast-hba-bay-map.json".text = builtins.toJSON diskBayMappings;

  systemd.services.beast-disk-bay-export = {
    description = "Export beast disk bay mapping for node exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = diskBayExporter;
    };
  };
}
