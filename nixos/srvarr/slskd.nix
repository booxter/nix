{
  config,
  hostInventory,
  ...
}:
let
  accounts = import ./accounts.nix;
  mediaDir = config.host.srvarrPaths.mediaDir;
  slskdRoot = "${mediaDir}/slskd";
  srvarrSpec = hostInventory.nixosHostSpecsByName.srvarr;
  apiPort = 5030;
  peerPort = srvarrSpec.wgNamespace.forwardedPorts.slskd;
  wgBridgeAddress = srvarrSpec.wgNamespace.bridgeAddress;
  wgNamespaceAddress = srvarrSpec.wgNamespace.namespaceAddress;
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
  users.users.slskd.uid = accounts.uids.slskd;

  sops.secrets = builtins.listToAttrs (
    map (name: {
      inherit name;
      value.restartUnits = [ "slskd.service" ];
    }) slskdSecretNames
  );

  sops.templates."slskd.env" = {
    owner = "slskd";
    group = "media";
    mode = "0400";
    restartUnits = [ "slskd.service" ];
    content = ''
      SLSKD_SLSK_USERNAME=${config.sops.placeholder.${secretPath "soulseek/username"}}
      SLSKD_SLSK_PASSWORD=${config.sops.placeholder.${secretPath "soulseek/password"}}
      SLSKD_USERNAME=${config.sops.placeholder.${secretPath "web/username"}}
      SLSKD_PASSWORD=${config.sops.placeholder.${secretPath "web/password"}}
      SLSKD_API_KEY=role=Administrator;cidr=${wgBridgeAddress}/32;${
        config.sops.placeholder.${secretPath "web/apiKey"}
      }
    '';
  };

  services.slskd = {
    enable = true;
    domain = null;
    group = "media";
    environmentFile = config.sops.templates."slskd.env".path;
    settings = {
      # Aurral uses only the API; do not expose slskd's interactive UI.
      headless = true;
      directories = {
        incomplete = "${slskdRoot}/incomplete";
        downloads = "${slskdRoot}/complete";
      };
      shares.directories = [ ];
      soulseek = {
        listen_ip_address = "0.0.0.0";
        listen_port = peerPort;
      };
      web = {
        ip_address = wgNamespaceAddress;
        port = apiPort;
        https.disabled = true;
      };
    };
  };

  systemd.services.slskd = {
    unitConfig.RequiresMountsFor = mediaDir;
    serviceConfig.UMask = "0002";
    vpnConfinement = {
      enable = true;
      vpnNamespace = "wg";
    };
  };

  # The API key crosses only the private host-to-namespace veth. Restrict both
  # the namespace firewall and slskd's own key to the host bridge address.
  host.vpnNamespaceBridgeAccess.tcpPorts = [ apiPort ];

  vpnNamespaces.wg.openVPNPorts = [
    {
      port = peerPort;
      protocol = "tcp";
    }
  ];
}
