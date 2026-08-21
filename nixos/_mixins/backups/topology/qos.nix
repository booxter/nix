{
  backupTopology,
  config,
  lib,
  ...
}:
let
  backups = config.host.backups;
  qosEnabled = backups.server != null && backups.server.offsite != null && backups.server.offsite.qos;
in
{
  host.qos.interfaces.wan = lib.mkIf qosEnabled {
    device = config.host.network.primaryInterface;
    limits.cloud-backup = {
      rateMbit = config.host.site.policies.backups.maxUploadMbit;
      match.users = backupTopology.server.offloadUsers;
    };
  };
}
