{
  config,
  facts,
  lib,
  ...
}:
let
  hostName = config.networking.hostName;
  provider = facts.backups.providers.${hostName} or null;
  hostLinks = facts.backups.links.${hostName} or { };
  cloudUploadRateMbit = config.host.site.policies.backups.maxUploadMbit;
  cloudQosEnabled = config.host.backups.server.enable;
  clientLinks = lib.concatMapAttrs (
    clientName:
    lib.mapAttrs' (
      linkName: link:
      lib.nameValuePair "${clientName}-${linkName}" (
        link
        // {
          inherit clientName linkName;
        }
      )
    )
  ) facts.backups.links;
  providedLinks = lib.filterAttrs (_: link: link.provider == hostName) clientLinks;
  clients = lib.mapAttrs' (
    _: link:
    lib.nameValuePair link.clientName {
      inherit (link) storageName;
      publicKey = link.publicKey or null;
      cloud = lib.optionalAttrs ((link.offsite or null) != null) (
        let
          offsite = provider.offsite.${link.offsite};
          prefix = "${offsite.prefix}/${link.storageName}";
        in
        {
          enable = true;
          repository = "b2:${offsite.bucketName}:${prefix}";
          inherit prefix;
          sourcePasswordFile =
            config.sops.secrets."backup/restic/${link.clientName}/cloud/localPassword".path;
          passwordFile = config.sops.secrets."backup/restic/${link.clientName}/cloud/password".path;
        }
      );
    }
  ) providedLinks;
  localLinks = lib.filterAttrs (_: link: (link.transport or "sftp") == "local") providedLinks;
  localClients = lib.mapAttrsToList (_: link: link.clientName) localLinks;
  localClient = if localClients == [ ] then null else builtins.head localClients;
  bucketNames =
    if provider == null then
      [ ]
    else
      lib.unique (lib.mapAttrsToList (_: offsite: offsite.bucketName) provider.offsite);
in
{
  config = lib.mkMerge [
    {
      host.backups.destinations = builtins.mapAttrs (_: link: {
        inherit (link)
          ingestUser
          provider
          repositoryPath
          ;
        transport = link.transport or "sftp";
        publicKey = link.publicKey or null;
        offsite = link.offsite or null;
      }) hostLinks;
    }
    (lib.mkIf cloudQosEnabled {
      assertions = [
        {
          assertion = config.host.network.primaryInterface != null;
          message = "backup cloud-offload policy requires host.network.primaryInterface";
        }
      ];

      host.backups.server.cloud.requiredUnits = [ "qos-wan.service" ];
      host.qos.interfaces.wan = {
        device = config.host.network.primaryInterface;
        limits.cloud-backup = {
          rateMbit = cloudUploadRateMbit;
          match.users = config.host.backups.server.generated.offloadUsers;
        };
      };
    })
    (lib.mkIf (provider != null) {
      assertions = [
        {
          assertion = builtins.length localClients <= 1;
          message = "backup provider ${hostName} may have at most one local client";
        }
        {
          assertion = builtins.length bucketNames == 1;
          message = "backup provider ${hostName} currently requires one shared cloud bucket";
        }
        {
          assertion =
            builtins.length (builtins.attrNames clients) == builtins.length (builtins.attrNames providedLinks);
          message = "backup provider ${hostName} may have only one link per client";
        }
      ];

      host.backups.server = {
        inherit clients localClient;
        inherit (provider) repositoryRoot;
        cloud.bucketName = builtins.head bucketNames;
      };

      host.backups.destinations = lib.mkMerge (
        lib.mapAttrsToList (_: link: {
          ${link.linkName}.user = config.host.backups.server.cloud.group;
        }) localLinks
      );
    })
  ];
}
