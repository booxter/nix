{
  backupClients,
  cloudBucketName,
  mkCloudSecret,
  sharedB2ApplicationKeyIdSecret,
  sharedB2ApplicationKeySecret,
}:
{
  beastPkgs,
  config,
  pkgs,
  ...
}:
let
  textfileDir = "/var/lib/prometheus-node-exporter-textfile";
  stateDir = "restic-cloud-usage-metrics";
  usageConfig = (pkgs.formats.json { }).generate "restic-cloud-usage-config.json" {
    buckets = [ cloudBucketName ];
    b2ApplicationKeyIdFile = config.sops.secrets.${sharedB2ApplicationKeyIdSecret}.path;
    b2ApplicationKeyFile = config.sops.secrets.${sharedB2ApplicationKeySecret}.path;
    repositories = map (name: {
      inherit name;
      backupJob = "restic-${name}-cloud-offload";
      backupTitle = "${name} Cloud Offload";
      bucket = cloudBucketName;
      inherit (backupClients.${name}.cloud) prefix repository;
      passwordFile = config.sops.secrets.${mkCloudSecret name "password"}.path;
    }) (builtins.attrNames backupClients);
  };
in
{
  systemd.tmpfiles.rules = [
    "d ${textfileDir} 0755 root root - -"
  ];

  systemd.services.restic-cloud-usage-export = {
    description = "Export restic cloud and B2 usage metrics";
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    after = [
      "network-online.target"
      "sops-install-secrets.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = stateDir;
      TimeoutStartSec = "2h";
      ExecStart = "${beastPkgs.restic-tools}/bin/restic-cloud-usage --config ${usageConfig} --state-file /var/lib/${stateDir}/state.json --metrics-file ${textfileDir}/restic-cloud-usage.prom --restic-cache-dir /var/lib/${stateDir}/restic-cache";
    };
  };

  systemd.timers.restic-cloud-usage-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/4:00:00";
      RandomizedDelaySec = "10m";
      Persistent = true;
      Unit = "restic-cloud-usage-export.service";
    };
  };
}
