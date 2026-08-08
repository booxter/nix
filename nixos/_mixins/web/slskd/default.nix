{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.services.slskd;
  hostCfg = config.host.slskd;
  hostname = config.networking.hostName;
  service = hostInventory.servicesById.slskd;
  instance = service.instances.${hostname} or { };
  mediaExport = hostInventory.storage.nfs.exports.media;
  mediaLayout = mediaExport.layout.slskd;
  isMediaServer = mediaExport.server == hostname;
  mediaDir = instance.mediaDir or "/var/lib/slskd-media";
  mediaPaths = builtins.mapAttrs (_: path: "${mediaDir}/${path}") mediaLayout;
  vpnRequirement = instance.vpnConfinement or { };
  vpnProfile = hostInventory.egressVpns.${vpnRequirement.profile};
  apiPort = 5030;
  peerPort = vpnRequirement.forwardedPort.port;
  vpnBridgeAddress = vpnProfile.bridgeAddress;
  vpnNamespaceAddress = vpnProfile.namespaceAddress;
  secretPath = name: "slskd/${name}";
  slskdSecretNames = [
    (secretPath "soulseek/username")
    (secretPath "soulseek/password")
    (secretPath "web/username")
    (secretPath "web/password")
    (secretPath "web/apiKey")
  ];
in
{
  options.host.slskd.enable = lib.mkOption {
    type = lib.types.bool;
    default = hostInventory.serviceRunsOn hostname service;
    readOnly = true;
    internal = true;
    description = "Whether inventory assigns slskd to this host.";
  };

  config = lib.mkIf hostCfg.enable {
    assertions = [
      {
        assertion = instance ? mediaDir && instance ? vpnConfinement;
        message = "The slskd inventory instance must define mediaDir and VPN confinement.";
      }
      {
        assertion = builtins.elem hostname mediaExport.clients;
        message = "The slskd host must be an authorized media NFS client.";
      }
    ];

    users.users.slskd.uid = hostInventory.serviceAccounts.slskd.uid;

    sops.secrets = builtins.listToAttrs (
      map (name: {
        inherit name;
        value.restartUnits = [ "slskd.service" ];
      }) slskdSecretNames
    );

    sops.templates."slskd.env" = {
      owner = "slskd";
      group = mediaExport.sharedGroup.name;
      mode = "0400";
      restartUnits = [ "slskd.service" ];
      content = ''
        SLSKD_SLSK_USERNAME=${config.sops.placeholder.${secretPath "soulseek/username"}}
        SLSKD_SLSK_PASSWORD=${config.sops.placeholder.${secretPath "soulseek/password"}}
        SLSKD_USERNAME=${config.sops.placeholder.${secretPath "web/username"}}
        SLSKD_PASSWORD=${config.sops.placeholder.${secretPath "web/password"}}
        SLSKD_API_KEY=role=Administrator;cidr=${vpnBridgeAddress}/32;${
          config.sops.placeholder.${secretPath "web/apiKey"}
        }
      '';
    };

    services.slskd = {
      enable = true;
      domain = null;
      group = mediaExport.sharedGroup.name;
      environmentFile = config.sops.templates."slskd.env".path;
      settings = {
        # Aurral uses only the API; do not expose slskd's interactive UI.
        headless = true;
        directories = {
          inherit (mediaPaths) incomplete;
          downloads = mediaPaths.complete;
        };
        shares.directories = [ ];
        soulseek = {
          listen_ip_address = "0.0.0.0";
          listen_port = peerPort;
        };
        web = {
          ip_address = vpnNamespaceAddress;
          port = apiPort;
          https.disabled = true;
        };
      };
    };

    host.nfs.mounts = lib.mkIf (!isMediaServer) {
      media = mediaDir;
    };

    systemd.services.slskd = {
      unitConfig.RequiresMountsFor = mediaDir;
      serviceConfig.UMask = "0002";
    };

    # The API key crosses only the private host-to-namespace veth. Restrict
    # both the namespace firewall and slskd's own key to the host bridge.
    host.vpnConfinement.implementations.slskd = {
      serviceEnabled = cfg.enable;
      systemdUnits = [ "slskd" ];
      bridgeTcpPorts = [ apiPort ];
    };
  };
}
