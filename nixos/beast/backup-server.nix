{
  beastPkgs,
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  backupRoot = "/volume2/backups/restic-prod";
  cloudOffloadUser = "restic-cloud";
  cloudBucketName = "ihar-restic-prod";
  cloudBackupRateBits = 10 * 1000 * 1000;
  cloudBackupCeilBits = 10 * 1000 * 1000 * 1000;
  # Keep cloud-copy uploads smaller so each B2 request finishes sooner under
  # the shaped uplink instead of timing out mid-pack.
  cloudCopyPackSize = 4;
  # Keep native B2 uploads serialized to stay close to the previous single-
  # transfer rclone path while we validate direct restic offload.
  cloudB2Connections = 1;
  # Add future backup sources here. Each client gets a dedicated SSH-only user,
  # its own repository path, and its own public key in config.
  backupClients = {
    beast = {
      publicKey = null;
      cloud = {
        repository = "b2:${cloudBucketName}:hosts/beast";
        prefix = "hosts/beast";
        pruneOpts = [
          "--keep-daily=14"
          "--keep-weekly=8"
          "--keep-monthly=12"
        ];
        timerConfig = {
          OnCalendar = "06:00";
          RandomizedDelaySec = "5m";
        };
      };
    };
    srvarr = {
      publicKey = readPublicKey ../../public-keys/restic/srvarr.pub;
      cloud = {
        repository = "b2:${cloudBucketName}:hosts/srvarr";
        prefix = "hosts/srvarr";
        pruneOpts = [
          "--keep-daily=14"
          "--keep-weekly=8"
          "--keep-monthly=12"
        ];
        timerConfig = {
          # Stagger cloud offload after host-side local backups have landed.
          OnCalendar = "06:00";
          RandomizedDelaySec = "5m";
        };
      };
    };
    org = {
      publicKey = readPublicKey ../../public-keys/restic/org.pub;
      # Restic repository namespaces are durable storage identities. Keep the
      # pre-rename namespace so local and B2 snapshot history remains intact.
      storageName = "orgvm";
      cloud = {
        repository = "b2:${cloudBucketName}:hosts/orgvm";
        prefix = "hosts/orgvm";
        pruneOpts = [
          "--keep-daily=14"
          "--keep-weekly=8"
          "--keep-monthly=12"
        ];
        timerConfig = {
          OnCalendar = "06:00";
          RandomizedDelaySec = "5m";
        };
      };
    };
    home = {
      publicKey = readPublicKey ../../public-keys/restic/home.pub;
      cloud = {
        repository = "b2:${cloudBucketName}:hosts/home";
        prefix = "hosts/home";
        pruneOpts = [
          "--keep-daily=14"
          "--keep-weekly=8"
          "--keep-monthly=12"
        ];
        timerConfig = {
          OnCalendar = "06:00";
          RandomizedDelaySec = "5m";
        };
      };
    };
    pki = {
      publicKey = readPublicKey ../../public-keys/restic/pki.pub;
      cloud = {
        repository = "b2:${cloudBucketName}:hosts/pki";
        prefix = "hosts/pki";
        pruneOpts = [
          "--keep-daily=14"
          "--keep-weekly=8"
          "--keep-monthly=12"
        ];
        timerConfig = {
          OnCalendar = "06:00";
          RandomizedDelaySec = "5m";
        };
      };
    };
  };
  mkBackupUser = name: "restic-${name}";
  mkBackupRepo = name: "${backupRoot}/hosts/${backupClients.${name}.storageName or name}";
  # Keep SSH/SFTP ingest and cloud offload as separate identities. The ingest
  # users are remote entry points, while offload users need access to cloud
  # credentials. Reusing the same account would let an SSH-exposed user read
  # offload secrets on the server, so non-local repos get a dedicated local-only
  # offload user plus explicit ACLs on the repository path.
  mkOffloadUser = name: if name == "beast" then cloudOffloadUser else "restic-${name}-offload";
  mkCloudStateDir = name: "restic-cloud-${name}";
  mkCloudSecret = name: path: "backup/restic/${name}/cloud/${path}";
  sshBackupClients = lib.filterAttrs (_: client: client.publicKey != null) backupClients;
  sharedB2ApplicationKeyIdSecret = "backup/restic/cloud/b2/applicationKeyId";
  sharedB2ApplicationKeySecret = "backup/restic/cloud/b2/applicationKey";
  mkCloudOffloadConfig =
    name:
    let
      backupRepo = mkBackupRepo name;
      srcPasswordFile = config.sops.secrets.${mkCloudSecret name "localPassword"}.path;
      dstPasswordFile = config.sops.secrets.${mkCloudSecret name "password"}.path;
      b2AccountIdFile = config.sops.secrets.${sharedB2ApplicationKeyIdSecret}.path;
      b2AccountKeyFile = config.sops.secrets.${sharedB2ApplicationKeySecret}.path;
    in
    (pkgs.formats.json { }).generate "restic-${name}-cloud-offload.json" {
      sourceRepository = backupRepo;
      sourcePasswordFile = srcPasswordFile;
      destinationRepository = backupClients.${name}.cloud.repository;
      destinationPasswordFile = dstPasswordFile;
      b2ApplicationKeyIdFile = b2AccountIdFile;
      b2ApplicationKeyFile = b2AccountKeyFile;
      b2Connections = cloudB2Connections;
      packSizeMib = cloudCopyPackSize;
      pruneOptions = backupClients.${name}.cloud.pruneOpts;
    };
  mkCloudOffloadCommand =
    name:
    utils.escapeSystemdExecArgs [
      (lib.getExe' beastPkgs.restic-tools "restic-cloud-offload")
      "--config"
      (mkCloudOffloadConfig name)
    ];
  cloudShapingConfig = (pkgs.formats.json { }).generate "restic-cloud-qos.json" {
    routeProbe = "1.1.1.1";
    users = map mkOffloadUser (builtins.attrNames backupClients);
    mark = 1;
    outerRateBits = cloudBackupCeilBits;
    cloudRateBits = cloudBackupRateBits;
  };
  cloudShapingCommand =
    action:
    utils.escapeSystemdExecArgs [
      (lib.getExe' beastPkgs.backup-server-tools "restic-cloud-qos")
      "--config"
      cloudShapingConfig
      action
    ];
  mkRepoAclConfig =
    name:
    (pkgs.formats.json { }).generate "restic-${name}-repo-acl.json" {
      repository = mkBackupRepo name;
      user = mkOffloadUser name;
      setfaclExecutable = lib.getExe' pkgs.acl "setfacl";
    };
  mkRepoAclCommand =
    name:
    utils.escapeSystemdExecArgs [
      (lib.getExe' beastPkgs.backup-server-tools "restic-repo-acl")
      "--config"
      (mkRepoAclConfig name)
    ];
in
{
  imports = [
    (import ./restic-tools.nix {
      inherit
        backupClients
        cloudBucketName
        mkCloudSecret
        sharedB2ApplicationKeyIdSecret
        sharedB2ApplicationKeySecret
        ;
    })
  ];

  systemd.tmpfiles.rules = map (
    name:
    let
      owner = if name == "beast" then cloudOffloadUser else mkBackupUser name;
    in
    "d ${mkBackupRepo name} 0750 ${owner} ${owner} - -"
  ) (builtins.attrNames backupClients);

  sops = {
    secrets =
      (builtins.listToAttrs (
        lib.concatMap (name: [
          {
            name = mkCloudSecret name "localPassword";
            value = {
              owner = mkOffloadUser name;
              group = mkOffloadUser name;
              mode = "0400";
            };
          }
          {
            name = mkCloudSecret name "password";
            value = {
              owner = mkOffloadUser name;
              group = mkOffloadUser name;
              mode = "0400";
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
  };

  users.users = builtins.listToAttrs (
    [
      {
        name = cloudOffloadUser;
        value = {
          isSystemUser = true;
          group = cloudOffloadUser;
          createHome = false;
          home = backupRoot;
          shell = pkgs.bash;
        };
      }
    ]
    ++ map (name: {
      name = mkOffloadUser name;
      value = {
        isSystemUser = true;
        group = mkOffloadUser name;
        createHome = false;
        home = backupRoot;
        shell = pkgs.bash;
        extraGroups = [ cloudOffloadUser ];
      };
    }) (builtins.attrNames sshBackupClients)
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
      name = mkOffloadUser name;
      value = { };
    }) (builtins.attrNames sshBackupClients)
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
        ExecStart = cloudShapingCommand "start";
        ExecStop = cloudShapingCommand "stop";
      };
    };
  }
  // builtins.listToAttrs (
    (map (name: {
      name = "restic-${name}-repo-acl";
      value = {
        description = "Grant ${mkOffloadUser name} access to ${name} restic repository";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        unitConfig.RequiresMountsFor = backupRoot;
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          Group = "root";
          ExecStart = mkRepoAclCommand name;
        };
      };
    }) (builtins.attrNames sshBackupClients))
    ++ (map (
      name:
      let
        repoAclDeps = lib.optional (builtins.hasAttr name sshBackupClients) "restic-${name}-repo-acl.service";
      in
      {
        name = "restic-${name}-cloud-offload";
        value = {
          description = "Offload ${name} restic backup repository to the cloud";
          restartIfChanged = false;
          stopIfChanged = false;
          wants = [
            "network-online.target"
            "restic-cloud-traffic-shaping.service"
            "sops-install-secrets.service"
          ]
          ++ repoAclDeps;
          after = [
            "network-online.target"
            "restic-cloud-traffic-shaping.service"
            "sops-install-secrets.service"
          ]
          ++ repoAclDeps;
          requires = [ "restic-cloud-traffic-shaping.service" ];
          unitConfig.RequiresMountsFor = backupRoot;
          serviceConfig = {
            Type = "oneshot";
            User = mkOffloadUser name;
            Group = mkOffloadUser name;
            StateDirectory = mkCloudStateDir name;
            Environment = "RESTIC_CACHE_DIR=/var/lib/${mkCloudStateDir name}/cache";
            ExecStart = mkCloudOffloadCommand name;
          };
        };
      }
    ) (builtins.attrNames backupClients))
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

  host.observability.backupMetrics.jobs = builtins.mapAttrs (name: _: {
    service = "restic-${name}-cloud-offload";
    title = "${name} Cloud Offload";
    phase = "cloud";
  }) backupClients;
}
