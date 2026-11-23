{ ... }:
{
  # Keep active torrent files open across bursts of NFS reads and writes.
  services.transmission.settings.open_file_limit = 128;

  host.transmission = {
    stateDir = "/data/.state/nixarr/transmission";
    dynamicIpUpdater = {
      cookieJarFile = "/data/.secret/mam.cookies";
    };
    vpn = {
      peerPort = 45486;
    };
    torrentPolicy.trackers = {
      # Hostnames live in the encrypted tracker_aliases mapping. Each alias
      # retains 100 completed torrents, with 30 days of age and 3 seed days
      # required before removing seeds averaging below 10 KiB/s over 14 seeding days.
      mam = { };
      pl = { };
      hnet = { };
      horg = { };
    };
    uploadLimit.initialKBytesPerSecond = 950;
  };
}
