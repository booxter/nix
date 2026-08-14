{
  config,
  lib,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config lib; };
  instance = model.resolved;
  settingsFormat = pkgs.formats.yaml { };
  secretNames = [
    "${instance.secretPrefix}/soulseek/username"
    "${instance.secretPrefix}/soulseek/password"
    "${instance.secretPrefix}/web/username"
    "${instance.secretPrefix}/web/password"
    "${instance.secretPrefix}/web/apiKey"
  ];
  secret = suffix: config.sops.placeholder."${instance.secretPrefix}/${suffix}";
  configuration = settingsFormat.generate "slskd.yml" (
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
  shares = instance.settings.shares.directories or [ ];
in
{
  config = lib.mkIf (instance != null) {
    users.users.${instance.user} = {
      isSystemUser = true;
      uid = config.host.storage.identities.users.${instance.user}.uid;
      group = instance.group;
    };

    host.storage.claims.${instance.storage.claim} = {
      directories = builtins.listToAttrs (
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
      attachments.slskd.unit = "slskd";
    };

    host.vpn.clients.slskd = {
      inherit (instance.vpn) namespace;
      serviceName = "slskd";
      bridgeTcpPorts = [ instance.api.port ];
      forwardedPorts.peer = {
        port = instance.vpn.peerPort;
        protocol = "tcp";
      };
    };

    sops.secrets = builtins.listToAttrs (
      map (name: {
        inherit name;
        value.restartUnits = [ "slskd.service" ];
      }) secretNames
    );

    sops.templates."slskd.env" = {
      owner = instance.user;
      group = instance.group;
      mode = "0400";
      restartUnits = [ "slskd.service" ];
      content = ''
        SLSKD_SLSK_USERNAME=${secret "soulseek/username"}
        SLSKD_SLSK_PASSWORD=${secret "soulseek/password"}
        SLSKD_USERNAME=${secret "web/username"}
        SLSKD_PASSWORD=${secret "web/password"}
        SLSKD_API_KEY=role=Administrator;cidr=${instance.namespace.bridgeAddress}/32;${secret "web/apiKey"}
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${instance.stateDir} 0750 ${instance.user} ${instance.group} - -"
    ];

    systemd.services.slskd = {
      description = "slskd Soulseek client";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = instance.user;
        Group = instance.group;
        Environment = [ "DOTNET_USE_POLLING_FILE_WATCHER=1" ];
        EnvironmentFile = config.sops.templates."slskd.env".path;
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
  };
}
