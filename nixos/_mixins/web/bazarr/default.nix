{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.bazarr;
  hostCfg = config.host.bazarr;
  hostname = config.networking.hostName;
  backupJob = config.host.backups.destinationJob;
  service = hostInventory.servicesById.bazarr;
  ssoGate = hostInventory.oauth2ProxyGateForService service.id;
  instance = service.instances.${hostname} or { };
  account = hostInventory.serviceAccounts.bazarr;
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaGroup = mediaExport.sharedGroup;
  isMediaServer = mediaExport.server == hostname;
  stateDir = cfg.dataDir;
  user = "bazarr";
  enforceAuthCommand = utils.escapeSystemdExecArgs [
    (lib.getExe cfg.authConfig.package)
    "--config"
    "${stateDir}/config/config.yaml"
    "--uid"
    (toString account.uid)
    "--gid"
    (toString mediaGroup.gid)
  ];
in
{
  options = {
    host.bazarr.enable = lib.mkOption {
      type = lib.types.bool;
      default = hostInventory.serviceRunsOn hostname service;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns Bazarr to this host.";
    };

    services.bazarr = {
      mediaDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/bazarr-media";
        description = "Local mount point for shared media storage.";
      };

      authConfig.package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./packages/bazarr-auth-config {
          atomicFileWrites = pkgs.atomic-file-writes;
        };
        description = "Package enforcing Bazarr reverse-proxy authentication.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf hostCfg.enable {
      assertions = [
        {
          assertion = instance ? dataDir && instance ? mediaDir;
          message = "The Bazarr inventory instance must define dataDir and mediaDir.";
        }
        {
          assertion = builtins.elem hostname mediaExport.clients;
          message = "The Bazarr host must be an authorized media NFS client.";
        }
        {
          assertion = config.host.backups.client.enable;
          message = "The Bazarr host must be a declared backup client.";
        }
      ];

      services.bazarr = {
        enable = true;
        dataDir = instance.dataDir;
        mediaDir = instance.mediaDir;
        group = mediaGroup.name;
        inherit user;
      };

      host.nfs.mounts = lib.mkIf (!isMediaServer) {
        media = instance.mediaDir;
      };

      systemd.tmpfiles.rules = [
        "d '${stateDir}' 0700 ${user} root - -"
      ];

      users.users.${user} = {
        extraGroups = lib.mkForce [ mediaGroup.name ];
        home = lib.mkForce "/var/empty";
        isSystemUser = true;
        uid = account.uid;
      };

      systemd.services.bazarr = {
        unitConfig.RequiresMountsFor = instance.mediaDir;
        serviceConfig = {
          ExecStartPre = "+${enforceAuthCommand}";
          UMask = lib.mkForce "0002";
        };
      };

      host.internalService.services.bazarr = {
        enable = true;
        upstream = "http://127.0.0.1:${toString cfg.listenPort}";
      };

      # Bazarr has no reverse-proxy auth mode here: its config has
      # `auth.type: null`, but its logout endpoint only accepts native form or
      # basic auth. Clear the oauth2-proxy cookies at nginx instead.
      host.sso.oauth2ProxyGates.${ssoGate.id}.extraLocationsByName.bazarr."= /api/system/account" = {
        return = "204";
        extraConfig = ''
          auth_request off;
          add_header Set-Cookie "${ssoGate.cookieName}=; Path=/; Max-Age=0; HttpOnly; Secure" always;
          add_header Set-Cookie "${ssoGate.cookieName}_0=; Path=/; Max-Age=0; HttpOnly; Secure" always;
          add_header Set-Cookie "${ssoGate.cookieName}_1=; Path=/; Max-Age=0; HttpOnly; Secure" always;
          add_header Set-Cookie "${ssoGate.cookieName}_2=; Path=/; Max-Age=0; HttpOnly; Secure" always;
          add_header Set-Cookie "${ssoGate.cookieName}_csrf=; Path=/; Max-Age=0; HttpOnly; Secure" always;
        '';
      };

      host.backups.jobs.${backupJob} = {
        paths = [ stateDir ];
        exclude = [
          "${stateDir}/logs"
          "${stateDir}/logs/**"
          "${stateDir}/cache"
          "${stateDir}/cache/**"
        ];
      };
    })
  ];
}
