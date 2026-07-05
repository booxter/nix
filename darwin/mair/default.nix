{
  config,
  hostInventory,
  username,
  ...
}:
let
  lan = hostInventory.site.lan;
  wgHome = hostInventory.site.wireguard.home;
in
{
  imports = [ ./nix-cache-preference.nix ];

  home-manager.users.${username} = {
    home.sessionVariables.SOPS_AGE_KEY_FILE = "/Users/${username}/.config/sops/age/mair-se.txt";
    home.file.".ssh/secretive.pub".source = ../../public-keys/mair-secretive.pub;
    programs.git.settings.user.signingKey = "/Users/${username}/.ssh/secretive.pub";
    programs.sshTicket.enableKnownHosts = true;
  };

  host.browser.firefox.touchIdPasskeys.enable = true;

  sops.secrets."wireguard/gwvm/privateKey" = {
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
      lan.domain
    ];
    privateKeyFile = config.sops.secrets."wireguard/gwvm/privateKey".path;

    peers = [
      {
        publicKey = "ftjXEviy3flbMlXVntXs/QDcDUWR9f38nIPAcDTe4Gc=";
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
