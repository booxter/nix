{
  config,
  lib,
  pkgs,
  ...
}:
let
  backupRoot = "/volume2/backups/restic-prod";
  # Add future backup sources here. Each client gets a dedicated SSH-only user,
  # its own repository path, and its own public key secret on beast.
  backupClients = {
    srvarr = { };
  };
  mkBackupUser = name: "restic-${name}";
  mkBackupRepo = name: "${backupRoot}/hosts/${name}";
in
{
  sops.secrets = builtins.listToAttrs (
    map (name: {
      name = "backup/restic/clients/${name}/ssh/publicKey";
      value = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    }) (builtins.attrNames backupClients)
  );

  users.users = builtins.listToAttrs (
    map (name: {
      name = mkBackupUser name;
      value = {
        isSystemUser = true;
        group = mkBackupUser name;
        createHome = false;
        home = backupRoot;
        shell = pkgs.bash;
        openssh.authorizedKeys.keyFiles = [ config.sops.secrets."backup/restic/clients/${name}/ssh/publicKey".path ];
      };
    }) (builtins.attrNames backupClients)
  );

  users.groups = builtins.listToAttrs (
    map (name: {
      name = mkBackupUser name;
      value = { };
    }) (builtins.attrNames backupClients)
  );

  services.openssh.extraConfig = lib.concatStringsSep "\n" (
    map (
      name: ''
        Match User ${mkBackupUser name}
          ForceCommand internal-sftp
          PasswordAuthentication no
          PermitTTY no
          X11Forwarding no
          AllowTcpForwarding no
      ''
    ) (builtins.attrNames backupClients)
  );

  systemd.services = builtins.listToAttrs (
    map (
      name:
      let
        backupUser = mkBackupUser name;
        backupRepo = mkBackupRepo name;
      in
      {
        name = "restic-${name}-backup-dir";
        value = {
          description = "Ensure ${name} backup repository directory exists";
          wantedBy = [ "multi-user.target" ];
          # Keep the local backup target available independently of Beast's Monday
          # 03:00 auto-upgrade slot; clients run backups only after the reboot window.
          unitConfig.RequiresMountsFor = backupRoot;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "restic-${name}-backup-dir" ''
              set -eu
              install -d -m 0750 -o root -g root "${backupRoot}"
              install -d -m 0750 -o root -g root "${backupRoot}/hosts"
              install -d -m 0750 -o ${backupUser} -g ${backupUser} "${backupRepo}"
            '';
          };
        };
      }
    ) (builtins.attrNames backupClients)
  );
}
