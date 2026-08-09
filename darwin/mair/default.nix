{
  config,
  hostInventory,
  lib,
  ...
}:
let
  username = config.host.username;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  lan = hostInventory.site.lan;
  wgHome = hostInventory.site.wireguard.home;
in
{
  system.stateVersion = 6;

  imports = [
    ./nix-cache-preference.nix
    ./opencode.nix
  ];

  home-manager.users.${username} = {
    home.stateVersion = "25.11";
    home.sessionVariables.SOPS_AGE_KEY_FILE = "/Users/${username}/.config/sops/age/mair-se.txt";
  };

  host.browser.firefox.touchIdPasskeys.enable = true;
  host.remoteGui.wayland.enable = true;
  host.secretive.enable = true;

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
        publicKey = readPublicKey ../../public-keys/wireguard/home-gateway.pub;
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
