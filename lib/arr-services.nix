{
  grafanaDisplayUrl ? "http://fana.local:3000/",
  grafanaProbeUrl ? "http://127.0.0.1:3000/",
  srvarrDisplayHost ? "srvarr.local",
  srvarrProbeHost ? "prox-srvarrvm",
  srvarrPorts,
}:
let
  mkExternal = id: title: url: icon: {
    inherit
      icon
      id
      title
      url
      ;
    probeUrl = url;
    scope = "external";
  };

  mkInternal = id: title: port: icon: {
    inherit
      icon
      id
      title
      ;
    probeUrl = "http://${srvarrProbeHost}:${toString port}/";
    scope = "internal";
    url = "http://${srvarrDisplayHost}:${toString port}/";
  };
in
[
  (mkExternal "jellyfin" "Jellyfin" "https://jf.ihar.dev" "sh:jellyfin")
  (mkExternal "jellyseerr" "Jellyseerr" "https://js.ihar.dev" "sh:jellyseerr")
  {
    icon = "sh:grafana";
    id = "grafana";
    probeUrl = grafanaProbeUrl;
    scope = "internal";
    title = "Grafana";
    url = grafanaDisplayUrl;
  }
  (mkInternal "radarr" "Radarr" srvarrPorts.radarr "sh:radarr")
  (mkInternal "sonarr" "Sonarr" srvarrPorts.sonarr "sh:sonarr")
  (mkInternal "lidarr" "Lidarr" srvarrPorts.lidarr "sh:lidarr")
  (mkExternal "audiobookshelf" "Audiobookshelf" "https://au.ihar.dev" "sh:audiobookshelf")
  (mkInternal "readarr" "Readarr" srvarrPorts.readarr "sh:readarr")
  (mkInternal "readarr-audio" "Readarr Audio" srvarrPorts.readarrAudio "sh:readarr")
  (mkInternal "bazarr" "Bazarr" srvarrPorts.bazarr "sh:bazarr")
  (mkInternal "prowlarr" "Prowlarr" srvarrPorts.prowlarr "sh:prowlarr")
  (mkInternal "transmission" "Transmission" srvarrPorts.transmission "sh:transmission")
  (mkInternal "sabnzbd" "SABNZB" srvarrPorts.sabnzbd
    "https://raw.githubusercontent.com/sabnzbd/sabnzbd/70d5134d28a0c1cddff49c97fa013cb67c356f9e/icons/logo-arrow.svg"
  )
]
