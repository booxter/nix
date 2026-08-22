{
  hostWhitelist,
  mediaDir,
  port,
  vpnNamespaceAddress,
}:
{
  misc = {
    complete_dir = "${mediaDir}/usenet/manual";
    dirscan_dir = "${mediaDir}/usenet/watch";
    download_dir = "${mediaDir}/usenet/.incomplete";
    host = vpnNamespaceAddress;
    host_whitelist = "${builtins.concatStringsSep "," hostWhitelist},";
    permissions = 775;
    inherit port;

    # Browser access is gated by oauth2-proxy in nginx. Integrations use the
    # API key, so SABnzbd itself may trust requests arriving through nginx.
    inet_exposure = 5;
    fixed_ports = true;

    bandwidth_max = "100M";
    bandwidth_perc = 100;
    cache_limit = "16G";

    direct_unpack = true;
    direct_unpack_tested = true;
    direct_unpack_threads = 30;
    pause_on_pwrar = 2;
    ignore_samples = true;
    pause_on_post_processing = true;
    unwanted_extensions = "iso,";
    action_on_unwanted_extensions = 2;

    receive_threads = 20;
    assembler_max_queue_size = 12;
  };

  categories."*" = {
    name = "*";
    order = 0;
    pp = 3;
    script = "Default";
    dir = "";
    newzbin = "";
    priority = 0;
  };
}
