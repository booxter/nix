{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  instance = model.resolved;
  secretNames = [
    "${instance.secretPrefix}/soulseek/username"
    "${instance.secretPrefix}/soulseek/password"
    "${instance.secretPrefix}/web/username"
    "${instance.secretPrefix}/web/password"
    "${instance.secretPrefix}/web/apiKey"
  ];
  secret = suffix: config.sops.placeholder."${instance.secretPrefix}/${suffix}";
in
{
  config = lib.mkIf (instance != null) {
    users.users.slskd.uid = config.host.storage.identities.users.slskd.uid;

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

    services.slskd = {
      enable = true;
      inherit (instance) package;
      user = instance.user;
      group = instance.group;
      domain = null;
      environmentFile = config.sops.templates."slskd.env".path;
      settings = lib.recursiveUpdate instance.settings {
        headless = true;
        directories = {
          incomplete = instance.incompleteDir;
          downloads = instance.completedDir;
        };
        shares.directories = instance.settings.shares.directories or [ ];
        soulseek = {
          listen_ip_address = "0.0.0.0";
          listen_port = instance.vpn.peerPort;
        };
        web = {
          ip_address = instance.namespace.namespaceAddress;
          port = instance.api.port;
          https.disabled = true;
        };
      };
    };

    systemd.services.slskd.serviceConfig.UMask = "0002";
  };
}
