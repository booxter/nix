{ config, pkgs, ... }:
let
  python = pkgs.python3.withPackages (ps: [ ps.sabctools ]);
in
{
  services.sabnzbd = {
    enable = true;
    settings = {
      logging.log_level = 2;
      misc = {
        host = "127.0.0.1";
        port = 8080;
        api_key = "0123456789abcdef0123456789abcdef";
        download_dir = "/var/lib/sabnzbd/incomplete";
        complete_dir = "/var/lib/sabnzbd/complete";
        direct_unpack = false;
        auto_browser = false;
      };
      servers.fixture = {
        name = "fixture";
        displayname = "Local NNTP fixture";
        host = "127.0.0.1";
        port = 119;
        connections = 1;
        ssl = false;
      };
    };
  };

  systemd.services.test-nntp = {
    wantedBy = [ "multi-user.target" ];
    # SABnzbd's end-to-end NNTP fixture serves real yEnc articles from the
    # file paths encoded in our generated NZBs. Traffic stays on loopback.
    serviceConfig.ExecStart = "${python}/bin/python ${config.services.sabnzbd.package}/tests/sabnews.py -p 119";
  };
}
