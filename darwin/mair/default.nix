{
  config,
  facts,
  ...
}:
let
  username = config.host.username;
  lan = facts.site.lan;
  wgHome = facts.site.wireguard.home;
in
{
  system.stateVersion = 6;

  imports = [
    ./nix-cache-preference.nix
    ./opencode.nix
  ];

  home-manager.users.${username} = {
    home.sessionVariables.SOPS_AGE_KEY_FILE = "/Users/${username}/.config/sops/age/mair-se.txt";
  };

  host = {
    hardware.isLaptop = true;
    remote-control = {
      client = {
        vnc.enable = true;
        wayland.enable = true;
        x11.enable = true;
      };
      server.vnc.enable = true;
    };
    secretive.enable = true;
  };

  sops.secrets."wireguard/gw/privateKey" = {
    owner = "root";
    group = "wheel";
    mode = "0400";
  };

  networking.wg-quick.interfaces.wg0 = {
    # Keep this as an on-demand tunnel on the laptop to avoid forcing it up on
    # every network. The interface is ready once deployed.
    autostart = false;
    address = [ wgHome.peers.mair.address ];
    dns = [
      lan.gateway.address
      config.host.network.lanDomain
    ];
    privateKeyFile = config.sops.secrets."wireguard/gw/privateKey".path;

    peers = [
      {
        publicKey = facts.public-keys.wireguard.home-gateway;
        endpoint = "${wgHome.gateway.publicEndpoint}:${toString wgHome.gateway.listenPort}";
        allowedIPs = [
          wgHome.cidr
          lan.cidr
        ];
        persistentKeepalive = 25;
      }
    ];
  };
}
