{ config, ... }:
{
  host.pinepods = {
    enable = true;
    publicHostName = "pod.${config.host.network.publicDomain}";
    storage = {
      claim = "media";
      relativePath = "podcasts/pinepods";
    };
    integrations = {
      searchApi.url = "https://search.pinepods.online/api/search";
      podPeople.url = "https://people.pinepods.online";
    };
  };

  # TODO: Migrate this existing cluster to PostgreSQL's NixOS-managed default
  # under /var/lib/postgresql, then remove this override and both tmpfiles
  # rules. They exist only to preserve the legacy on-disk location safely.
  services.postgresql.dataDir = "/data/.state/nixarr/pinepods/postgresql";
  systemd.tmpfiles.rules = [
    "d /data/.state/nixarr/pinepods 0711 root root - -"
    "d /data/.state/nixarr/pinepods/postgresql 0700 postgres postgres - -"
  ];
}
