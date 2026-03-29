{
  config,
  lib,
  pkgs,
  ...
}:
let
  backupRoot = "/volume2/backups/restic-prod";
  cloudOffloadUser = "restic-cloud";
  cloudBackupRate = "10mbit";
  cloudBackupCeil = "10gbit";
  # Keep cloud-copy uploads smaller so each B2 request finishes sooner under
  # the shaped uplink instead of timing out mid-pack.
  cloudCopyPackSize = "4";
  # Add future backup sources here. Each client gets a dedicated SSH-only user,
  # its own repository path, and its own public key in config.
  backupClients = {
    beast = {
      publicKey = null;
      cloud = {
        repository = "rclone:b2:ihar-restic-prod/hosts/beast";
        pruneOpts = [
          "--keep-daily=14"
          "--keep-weekly=8"
          "--keep-monthly=12"
        ];
        timerConfig = {
          OnCalendar = "05:30";
          RandomizedDelaySec = "30m";
        };
      };
    };
    srvarr = {
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5uWCS2lW2JVBHPltnWuYtB5866DUSJ9Ayhz4hgY1T2";
      cloud = {
        repository = "rclone:b2:ihar-restic-prod/hosts/srvarr";
        pruneOpts = [
          "--keep-daily=14"
          "--keep-weekly=8"
          "--keep-monthly=12"
        ];
        timerConfig = {
          # Stagger cloud offload after host-side local backups have landed.
          OnCalendar = "05:30";
          RandomizedDelaySec = "30m";
        };
      };
    };
  };
  mkBackupUser = name: "restic-${name}";
  mkBackupRepo = name: "${backupRoot}/hosts/${name}";
  mkCloudSecret = name: path: "backup/restic/${name}/cloud/${path}";
  sshBackupClients = lib.filterAttrs (_: client: client.publicKey != null) backupClients;
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

      restic_dst() {
        ${pkgs.restic}/bin/restic -r "$dst_repo" --password-file "$dst_password_file" "$@"
      }

      cleanup() {
        exit_code=$?
        if [ "$exit_code" -ne 0 ]; then
          restic_dst unlock || true
        fi
      }
      trap cleanup EXIT

      if ! restic_dst cat config >/dev/null 2>&1; then
        restic_dst \
          init \
          --from-repo "$src_repo" \
          --from-password-file "$src_password_file" \
          --copy-chunker-params
      fi

      # The destination repo is only used by this offload job, so clear stale
      # locks left behind by previously failed runs before starting new work.
      restic_dst unlock || true

      restic_dst \
        -o 'rclone.args=serve restic --stdio --b2-hard-delete --transfers 1 --checkers 1 --tpslimit 2 --tpslimit-burst 1 --low-level-retries 20' \
        --pack-size ${cloudCopyPackSize} \
        copy \
        --from-repo "$src_repo" \
        --from-password-file "$src_password_file" \
        --verbose

      restic_dst unlock || true

      restic_dst \
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
        ${pkgs.iproute2}/bin/tc qdisc add dev "$iface" parent 1:10 handle 10: fq_codel
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
  systemd.tmpfiles.rules = builtins.concatLists (
    map (
      name:
      let
        owner = if name == "beast" then cloudOffloadUser else mkBackupUser name;
      in
      [
        "d ${mkBackupRepo name} 0750 ${owner} ${owner} - -"
      ]
    ) (builtins.attrNames backupClients)
  );

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
            type = b2
            account = ${config.sops.placeholder.${sharedB2ApplicationKeyIdSecret}}
            key = ${config.sops.placeholder.${sharedB2ApplicationKeySecret}}
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
          extraGroups = map mkBackupUser (builtins.attrNames sshBackupClients);
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
        openssh.authorizedKeys.keys = [ sshBackupClients.${name}.publicKey ];
      };
    }) (builtins.attrNames sshBackupClients)
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
    }) (builtins.attrNames sshBackupClients)
  );

  services.openssh.extraConfig = lib.concatStringsSep "\n" (
    map (name: ''
      Match User ${mkBackupUser name}
        ForceCommand internal-sftp
        PasswordAuthentication no
        PermitTTY no
        X11Forwarding no
        AllowTcpForwarding no
    '') (builtins.attrNames sshBackupClients)
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
    (map (name: {
      name = "restic-${name}-cloud-offload";
      value = {
        description = "Offload ${name} restic backup repository to the cloud";
        restartIfChanged = false;
        stopIfChanged = false;
        wants = [
          "network-online.target"
          "restic-cloud-traffic-shaping.service"
          "sops-install-secrets.service"
        ];
        after = [
          "network-online.target"
          "restic-cloud-traffic-shaping.service"
          "sops-install-secrets.service"
        ];
        requires = [ "restic-cloud-traffic-shaping.service" ];
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
    }) (builtins.attrNames backupClients))
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
