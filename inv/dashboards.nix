{
  internalPki,
  lanDomain,
}:
let
  search = {
    serviceId = "goo";
    queryPath = "/search?q={QUERY}";
  };
in
{
  categories = [
    {
      id = "user";
      title = "User Apps";
      serviceIds = [
        "jellyfin"
        "seerr"
        "romm"
        "aurral"
        "audiobookshelf"
        "pinepods"
        "shelfmark"
        "vikunja"
        "goo"
      ];
    }
    {
      id = "media-admin";
      title = "Media Admin";
      serviceIds = [
        "watchstate"
        "houndarr"
        "radarr"
        "sonarr"
        "lidarr"
        "bazarr"
        "prowlarr"
        "transmission"
        "sabnzbd"
      ];
    }
    {
      id = "infrastructure";
      title = "Infrastructure";
      serviceIds = [
        "grafana"
        "home"
        "paperless"
        "paperless-gpt"
      ];
      links = [
        {
          icon = "sh:proxmox";
          title = "Proxmox VE";
          url = "https://proxmox.${lanDomain}/";
        }
        {
          icon = "sh:smallstep";
          title = "PKI Root CA";
          url =
            "https://${internalPki.providerHost}:"
            + toString internalPki.server.port
            + internalPki.server.rootsPath;
        }
      ];
    }
  ];

  profiles = [
    {
      id = "internal";
      endpointServiceId = "glance";
      categoryIds = [
        "user"
        "media-admin"
        "infrastructure"
      ];
      inherit search;
    }
    {
      id = "public";
      endpointServiceId = "dash";
      categoryIds = [ "user" ];
      inherit search;
    }
  ];
}
