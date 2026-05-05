{
  config,
  lib,
  pkgs,
  ...
}:
let
  beastSftpBackupNames = builtins.attrNames (
    lib.filterAttrs (
      _: backup:
      let
        repository = backup.repository or null;
      in
      repository != null && builtins.match "^sftp:[^@]+@beast:.*" repository != null
    ) config.services.restic.backups
  );
  reapResticSshHelper = pkgs.writeShellApplication {
    name = "reap-restic-sftp-ssh-helper";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
    ];
    text = ''
      set -euo pipefail

      cgroup_path="$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)"
      procs_file="/sys/fs/cgroup''${cgroup_path}/cgroup.procs"

      [ -r "$procs_file" ] || exit 0

      while read -r pid; do
        [ -n "$pid" ] || continue
        [ "$pid" = "$$" ] && continue

        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        [ "$comm" = "ssh" ] || continue

        echo "reaping leftover restic ssh helper pid $pid"
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
      done < "$procs_file"
    '';
  };
in
{
  config = lib.mkIf (beastSftpBackupNames != [ ]) {
    systemd.services = builtins.listToAttrs (
      map (name: {
        name = "restic-backups-${name}";
        value.postStop = lib.mkAfter ''
          ${lib.getExe reapResticSshHelper}
        '';
      }) beastSftpBackupNames
    );
  };
}
