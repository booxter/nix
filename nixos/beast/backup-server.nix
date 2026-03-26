{
  config,
  lib,
  pkgs,
  ...
}:
let
  backupRoot = "/volume2/backups/restic-prod";
  cloudOffloadUser = "restic-cloud";
  cloudBackupRate = "4mbit";
  cloudBackupCeil = "10gbit";
  # Add future backup sources here. Each client gets a dedicated SSH-only user,
  # its own repository path, and its own public key in config.
  backupClients = {
    srvarr = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5uWCS2lW2JVBHPltnWuYtB5866DUSJ9Ayhz4hgY1T2";
      cloud = {
        repository = "rclone:b2:ihar-restic-prod/hosts/srvarr";
        pruneOpts = [
          "--keep-daily 14"
          "--keep-weekly 8"
          "--keep-monthly 12"
        ];
        timerConfig = {
          # Stagger cloud offload after the client-side local backup.
          OnCalendar = "07:15";
          RandomizedDelaySec = "45m";
        };
      };
    };
  };
  mkBackupUser = name: "restic-${name}";
  mkBackupRepo = name: "${backupRoot}/hosts/${name}";
  mkCloudSecret = name: path: "backup/restic/${name}/cloud/${path}";
  sharedB2ApplicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  sharedB2ApplicationKeySecret = "backup/restic/cloud/b2/applicationKey";
  mkCloudTemplate = name: "restic-${name}-cloud-rclone.conf";
  mkCloudOffloadScript =
    name:
    let
      backupRepo = mkBackupRepo name;
      cloudSecret = path: config.sops.secrets.${mkCloudSecret name path}.path;
      rcloneConfigFile = config.sops.templates.${mkCloudTemplate name}.path;
      pruneArgs = lib.escapeShellArgs backupClients.${name}.cloud.pruneOpts;
    in
    pkgs.writeShellScript "restic-${name}-cloud-offload" ''
      set -euo pipefail

      export RCLONE_CONFIG="${rcloneConfigFile}"

      dst_repo="${backupClients.${name}.cloud.repository}"
      src_repo="${backupRepo}"
      src_password_file="${cloudSecret "localPassword"}"
      dst_password_file="${cloudSecret "password"}"

      if ! ${pkgs.restic}/bin/restic -r "$dst_repo" --password-file "$dst_password_file" cat config >/dev/null 2>&1; then
        ${pkgs.restic}/bin/restic \
          -r "$dst_repo" \
          --password-file "$dst_password_file" \
          init \
          --from-repo "$src_repo" \
          --from-password-file "$src_password_file" \
          --copy-chunker-params
      fi

      ${pkgs.restic}/bin/restic \
        -r "$dst_repo" \
        --password-file "$dst_password_file" \
        copy \
        --from-repo "$src_repo" \
        --from-password-file "$src_password_file" \
        --verbose

      ${pkgs.restic}/bin/restic \
        -r "$dst_repo" \
        --password-file "$dst_password_file" \
        forget \
        --prune \
        ${pruneArgs}
    '';
  cloudShapingScript = pkgs.writeShellScript "restic-cloud-traffic-shaping" ''
    set -euo pipefail

    iface="$(${pkgs.iproute2}/bin/ip -o route get 1.1.1.1 | ${pkgs.gawk}/bin/awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
    if [ -z "$iface" ]; then
      echo "failed to determine default egress interface" >&2
      exit 1
    fi

    uid="$(${pkgs.coreutils}/bin/id -u ${cloudOffloadUser})"

    case "''${1:-start}" in
      start)
        ${pkgs.nftables}/bin/nft delete table inet backup_cloud_shaping 2>/dev/null || true
        ${pkgs.nftables}/bin/nft add table inet backup_cloud_shaping
        ${pkgs.nftables}/bin/nft \
          "add chain inet backup_cloud_shaping output { type route hook output priority mangle; policy accept; }"
        ${pkgs.nftables}/bin/nft \
          add rule inet backup_cloud_shaping output meta skuid "$uid" meta mark set 0x1

        ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root 2>/dev/null || true
        ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" root handle 1: htb default 20 r2q 1000
        ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1: classid 1:1 htb rate ${cloudBackupCeil} ceil ${cloudBackupCeil}
        ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:10 htb rate ${cloudBackupRate} ceil ${cloudBackupRate}
        ${pkgs.iproute2}/bin/tc class add dev "$iface" parent 1:1 classid 1:20 htb rate ${cloudBackupCeil} ceil ${cloudBackupCeil}
        ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:10 handle 10: cake bandwidth ${cloudBackupRate} besteffort wash
        ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:20 handle 20: fq_codel
        ${pkgs.iproute2}/bin/tc filter add dev "$iface" parent 1: protocol ip prio 10 handle 1 fw classid 1:10
        ${pkgs.iproute2}/bin/tc filter add dev "$iface" parent 1: protocol ipv6 prio 11 handle 1 fw classid 1:10
        ;;
      stop)
        ${pkgs.nftables}/bin/nft delete table inet backup_cloud_shaping 2>/dev/null || true
        ${pkgs.iproute2}/bin/tc qdisc del dev "$iface" root 2>/dev/null || true
        ;;
      *)
        echo "usage: $0 [start|stop]" >&2
        exit 2
        ;;
    esac
  '';
in
{
  sops = {
    secrets =
      (builtins.listToAttrs (
        lib.concatMap (name: [
          {
            name = mkCloudSecret name "localPassword";
            value = {
              group = cloudOffloadUser;
              mode = "0440";
            };
          }
          {
            name = mkCloudSecret name "password";
            value = {
              group = cloudOffloadUser;
              mode = "0440";
            };
          }
        ]) (builtins.attrNames backupClients)
      ))
      // {
        # Shared cloud backend credentials; repo passwords remain per-host.
        ${sharedB2ApplicationKeyIdSecret} = {
          group = cloudOffloadUser;
          mode = "0440";
        };
        ${sharedB2ApplicationKeySecret} = {
          group = cloudOffloadUser;
          mode = "0440";
        };
      };

    templates = builtins.listToAttrs (
      map (name: {
        name = mkCloudTemplate name;
        value = {
          owner = cloudOffloadUser;
          group = cloudOffloadUser;
          mode = "0400";
          content = ''
            [b2]
            type = s3
            provider = Other
            access_key_id = ${config.sops.placeholder.${sharedB2ApplicationKeyIdSecret}}
            secret_access_key = ${config.sops.placeholder.${sharedB2ApplicationKeySecret}}
            endpoint = s3.us-east-005.backblazeb2.com
            no_check_bucket = true
          '';
        };
      }) (builtins.attrNames backupClients)
    );
  };

  users.users = builtins.listToAttrs (
    [
      {
        name = cloudOffloadUser;
        value = {
          isSystemUser = true;
          group = cloudOffloadUser;
          extraGroups = map mkBackupUser (builtins.attrNames backupClients);
          createHome = false;
          home = backupRoot;
          shell = pkgs.bash;
        };
      }
    ]
    ++ map (name: {
      name = mkBackupUser name;
      value = {
        isSystemUser = true;
        group = mkBackupUser name;
        createHome = false;
        home = backupRoot;
        shell = pkgs.bash;
        openssh.authorizedKeys.keys = [ backupClients.${name}.publicKey ];
      };
    }) (builtins.attrNames backupClients)
  );

  users.groups = builtins.listToAttrs (
    [
      {
        name = cloudOffloadUser;
        value = { };
      }
    ]
    ++ map (name: {
      name = mkBackupUser name;
      value = { };
    }) (builtins.attrNames backupClients)
  );

  services.openssh.extraConfig = lib.concatStringsSep "\n" (
    map (name: ''
      Match User ${mkBackupUser name}
        ForceCommand internal-sftp
        PasswordAuthentication no
        PermitTTY no
        X11Forwarding no
        AllowTcpForwarding no
    '') (builtins.attrNames backupClients)
  );

  systemd.services = {
    restic-cloud-traffic-shaping = {
      description = "Shape cloud backup offload traffic";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cloudShapingScript} start";
        ExecStop = "${cloudShapingScript} stop";
      };
    };
  }
  // builtins.listToAttrs (
    lib.concatMap (
      name:
      let
        backupUser = mkBackupUser name;
        backupRepo = mkBackupRepo name;
      in
      [
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
                  # Parent directories must be traversable by backup users; keep
                  # per-client repository directories private instead.
                  install -d -m 0755 -o root -g root "${backupRoot}"
                  install -d -m 0755 -o root -g root "${backupRoot}/hosts"
                  install -d -m 0750 -o ${backupUser} -g ${backupUser} "${backupRepo}"
                  ${pkgs.acl}/bin/setfacl -R -m u:${cloudOffloadUser}:rwX "${backupRepo}"
                  ${pkgs.findutils}/bin/find "${backupRepo}" -type d -exec ${pkgs.acl}/bin/setfacl -m d:u:${cloudOffloadUser}:rwX {} +
              '';
            };
          };
        }
        {
          name = "restic-${name}-cloud-offload";
          value = {
            description = "Offload ${name} restic backup repository to the cloud";
            wants = [
              "network-online.target"
              "restic-cloud-traffic-shaping.service"
              "sops-install-secrets.service"
            ];
            after = [
              "network-online.target"
              "restic-${name}-backup-dir.service"
              "restic-cloud-traffic-shaping.service"
              "sops-install-secrets.service"
            ];
            requires = [
              "restic-${name}-backup-dir.service"
              "restic-cloud-traffic-shaping.service"
            ];
            unitConfig.RequiresMountsFor = backupRoot;
            serviceConfig = {
              Type = "oneshot";
              User = cloudOffloadUser;
              Group = cloudOffloadUser;
              StateDirectory = "restic-cloud";
              Environment = "RESTIC_CACHE_DIR=/var/lib/restic-cloud/cache";
              ExecStart = mkCloudOffloadScript name;
            };
          };
        }
      ]
    ) (builtins.attrNames backupClients)
  );

  systemd.timers = builtins.listToAttrs (
    map (name: {
      name = "restic-${name}-cloud-offload";
      value = {
        wantedBy = [ "timers.target" ];
        timerConfig = backupClients.${name}.cloud.timerConfig;
      };
    }) (builtins.attrNames backupClients)
  );
}
