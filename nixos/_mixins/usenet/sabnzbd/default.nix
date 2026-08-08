{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.services.sabnzbd;
  hostCfg = config.host.sabnzbd;
  hostname = config.networking.hostName;
  service = hostInventory.servicesById.sabnzbd;
  instance = service.instances.${hostname} or { };
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaDir = instance.mediaDir or "/var/lib/sabnzbd-media";
  absolutePaths = builtins.mapAttrs (
    _: value: if builtins.isAttrs value then absolutePaths value else "${mediaDir}/${value}"
  );
  mediaPaths = absolutePaths mediaExport.layout.sabnzbd;
  isMediaServer = mediaExport.server == hostname;
  vpnRequirement = instance.vpnConfinement or { };
  vpnProfile = hostInventory.egressVpns.${vpnRequirement.profile};
  port = 6336;
  user = "sabnzbd";
  vpnNamespaceAddress = vpnProfile.namespaceAddress;
  servers = hostInventory.usenet.sabnzbd.servers;
  serverNames = builtins.attrNames servers;
  serverSecret = server: field: "sabnzbd/servers/${server}/${field}";
  secretNames = [
    "sabnzbd/apiKey"
    "sabnzbd/nzbKey"
  ]
  ++ lib.concatMap (
    server:
    map (serverSecret server) [
      "username"
      "password"
    ]
  ) serverNames;
  serverSecretIni = lib.concatMapStringsSep "\n\n" (server: ''
    [[${server}]]
    username = ${builtins.getAttr (serverSecret server "username") config.sops.placeholder}
    password = ${builtins.getAttr (serverSecret server "password") config.sops.placeholder}
  '') serverNames;
  directoryRule = mode: path: "d '${path}' ${mode} ${user} ${mediaExport.sharedGroup.name} - -";
  directoryRules = [
    (directoryRule "0755" mediaPaths.root)
    (directoryRule "0755" mediaPaths.incomplete)
    (directoryRule "0775" mediaPaths.watch)
    (directoryRule "0775" mediaPaths.complete)
  ]
  ++ map (directoryRule "0775") (builtins.attrValues mediaPaths.categories);
in
{
  imports = [ ./exporter.nix ];

  options = {
    host.sabnzbd.enable = lib.mkOption {
      type = lib.types.bool;
      default = hostInventory.serviceRunsOn hostname service;
      readOnly = true;
      internal = true;
      description = "Whether inventory assigns SABnzbd to this host.";
    };

    services.sabnzbd.exporter.enable = lib.mkEnableOption "SABnzbd Prometheus exporter";
  };

  config = lib.mkIf hostCfg.enable {
    assertions = [
      {
        assertion = instance ? mediaDir && instance ? vpnConfinement;
        message = "The SABnzbd inventory instance must define mediaDir and VPN confinement.";
      }
      {
        assertion = builtins.elem hostname mediaExport.clients;
        message = "The SABnzbd host must be an authorized media NFS client.";
      }
    ];

    sops.secrets = lib.genAttrs secretNames (_: { });

    sops.templates."sabnzbd-secret.ini" = {
      owner = user;
      group = mediaExport.sharedGroup.name;
      mode = "0400";
      content = ''
        [misc]
        api_key = ${config.sops.placeholder."sabnzbd/apiKey"}
        nzb_key = ${config.sops.placeholder."sabnzbd/nzbKey"}

        [servers]
        ${serverSecretIni}
      '';
    };

    services.sabnzbd = {
      enable = true;
      allowConfigWrite = false;
      configFile = null;
      group = mediaExport.sharedGroup.name;
      secretFiles = [ config.sops.templates."sabnzbd-secret.ini".path ];
      settings = import ./settings.nix {
        language = hostInventory.regional.language.code;
        hostWhitelist = [ hostname ] ++ hostInventory.toInternalServiceHosts "sabnzbd";
        inherit
          port
          servers
          vpnNamespaceAddress
          ;
        paths = mediaPaths;
      };
      user = user;
      exporter.enable = true;
    };

    host.nfs.mounts = lib.mkIf (!isMediaServer) {
      media = mediaDir;
    };

    systemd.tmpfiles.rules = directoryRules;

    systemd.services.sabnzbd = {
      unitConfig.RequiresMountsFor = mediaDir;
      serviceConfig.Restart = "on-failure";
    };

    users.users.${user}.uid = hostInventory.serviceAccounts.sabnzbd.uid;

    host.vpnConfinement.implementations.sabnzbd = {
      serviceEnabled = cfg.enable;
      systemdUnits = [ "sabnzbd" ];
      bridgeTcpPorts = [ port ];
    };

    services.nginx.virtualHosts."127.0.0.1:${toString port}" = {
      listen = lib.mkForce [
        {
          addr = "127.0.0.1";
          inherit port;
        }
      ];
      locations."/" = {
        recommendedProxySettings = true;
        proxyWebsockets = true;
        proxyPass = lib.mkForce "http://${vpnNamespaceAddress}:${toString port}";
      };
    };

    host.internalService.services.sabnzbd = {
      enable = true;
      upstream = "http://127.0.0.1:${toString port}";
    };
  };
}
