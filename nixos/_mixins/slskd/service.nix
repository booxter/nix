{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  settingsFormat = pkgs.formats.yaml { };
  secretNames = instance: [
    "${instance.secretPrefix}/soulseek/username"
    "${instance.secretPrefix}/soulseek/password"
    "${instance.secretPrefix}/web/username"
    "${instance.secretPrefix}/web/password"
    "${instance.secretPrefix}/web/apiKey"
  ];
  environmentTemplate =
    instance:
    let
      secret = suffix: config.sops.placeholder."${instance.secretPrefix}/${suffix}";
    in
    {
      owner = instance.user;
      group = instance.group;
      mode = "0400";
      restartUnits = [ "${instance.unitName}.service" ];
      content = ''
        SLSKD_SLSK_USERNAME=${secret "soulseek/username"}
        SLSKD_SLSK_PASSWORD=${secret "soulseek/password"}
        SLSKD_USERNAME=${secret "web/username"}
        SLSKD_PASSWORD=${secret "web/password"}
        SLSKD_API_KEY=role=Administrator;cidr=${instance.namespace.bridgeAddress}/32;${secret "web/apiKey"}
      '';
    };
  configurationFile =
    instance:
    settingsFormat.generate "${instance.unitName}.yml" (
      lib.recursiveUpdate instance.settings {
        remote_configuration = false;
        headless = true;
        flags.no_version_check = true;
        logger.disk = false;
        directories = {
          incomplete = instance.incompleteDir;
          downloads = instance.completedDir;
        };
        soulseek = {
          listen_ip_address = "0.0.0.0";
          listen_port = instance.vpn.peerPort;
        };
        web = {
          ip_address = instance.namespace.namespaceAddress;
          port = instance.api.port;
          https.disabled = true;
        };
      }
    );
  service =
    instance:
    let
      configuration = configurationFile instance;
      shares = instance.settings.shares.directories or [ ];
    in
    {
      description = "slskd instance ${instance.name}";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ instance.claim.mountPoint ];
      serviceConfig = {
        Type = "simple";
        User = instance.user;
        Group = instance.group;
        Environment = [ "DOTNET_USE_POLLING_FILE_WATCHER=1" ];
        EnvironmentFile = config.sops.templates."${instance.unitName}.env".path;
        ExecStart = "${lib.getExe instance.package} --app-dir ${instance.stateDir} --config ${configuration}";
        Restart = "on-failure";
        UMask = "0002";
        ReadOnlyPaths = shares;
        ReadWritePaths = [
          instance.stateDir
          instance.incompleteDir
          instance.completedDir
        ];
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
      };
    };
  directoryRequests = lib.foldl' lib.recursiveUpdate { } (
    lib.mapAttrsToList (_: instance: {
      ${instance.storage.claim}.directories = builtins.listToAttrs (
        map
          (relativePath: {
            name = relativePath;
            value = {
              owner = instance.user;
              group = instance.group;
              mode = "2775";
            };
          })
          [
            instance.storage.relativePath
            "${instance.storage.relativePath}/incomplete"
            "${instance.storage.relativePath}/complete"
          ]
      );
    }) model.resolved
  );
in
{
  config = lib.mkIf (model.resolved != { }) {
    users.users.${model.cfg.user} = {
      isSystemUser = true;
      uid = config.host.accounts.users.${model.cfg.user}.uid;
      inherit (model.cfg) group;
    };

    host.storage.claims = directoryRequests;

    host.vpn.clients = lib.mapAttrs' (
      _: instance:
      lib.nameValuePair instance.vpnClientName {
        inherit (instance.vpn) namespace;
        serviceName = instance.unitName;
        bridgeTcpPorts = [ instance.api.port ];
        forwardedPorts.peer = {
          port = instance.vpn.peerPort;
          protocol = "tcp";
        };
      }
    ) model.resolved;

    sops.secrets = builtins.listToAttrs (
      builtins.concatMap (
        instance:
        map (name: {
          inherit name;
          value.restartUnits = [ "${instance.unitName}.service" ];
        }) (secretNames instance)
      ) (builtins.attrValues model.resolved)
    );

    sops.templates = lib.mapAttrs' (
      _: instance: lib.nameValuePair "${instance.unitName}.env" (environmentTemplate instance)
    ) model.resolved;

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      _: instance: "d ${instance.stateDir} 0750 ${instance.user} ${instance.group} - -"
    ) model.resolved;

    systemd.services = lib.mapAttrs' (
      _: instance: lib.nameValuePair instance.unitName (service instance)
    ) model.resolved;
  };
}
