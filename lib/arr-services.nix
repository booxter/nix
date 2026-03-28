{
  grafanaDisplayUrl ? "http://fana.local:3000/",
  grafanaProbeUrl ? "http://127.0.0.1:3000/",
  srvarrDisplayHost ? "srvarr.local",
  srvarrProbeHost ? "prox-srvarrvm",
  srvarrPorts,
}:
let
  mkExternal = id: title: url: icon: probeUrl: {
    inherit
      icon
      id
      probeUrl
      title
      url
      ;
    scope = "external";
  };

  mkInternal = id: title: port: icon: probePath: {
    inherit
      icon
      id
      title
      ;
    probeUrl = "http://${srvarrProbeHost}:${toString port}${probePath}";
    scope = "internal";
    url = "http://${srvarrDisplayHost}:${toString port}/";
  };
in
[
  (mkExternal "jellyfin" "Jellyfin" "https://jf.ihar.dev" "sh:jellyfin" "https://jf.ihar.dev/web/")
  (mkExternal "jellyseerr" "Jellyseerr" "https://js.ihar.dev" "sh:jellyseerr"
    "https://js.ihar.dev/login"
  )
  {
    icon = "sh:grafana";
    id = "grafana";
    probeUrl = "${grafanaProbeUrl}login";
    scope = "internal";
    title = "Grafana";
    url = grafanaDisplayUrl;
  }
  (mkInternal "radarr" "Radarr" srvarrPorts.radarr "sh:radarr" "/login")
  (mkInternal "sonarr" "Sonarr" srvarrPorts.sonarr "sh:sonarr" "/login")
  (mkInternal "lidarr" "Lidarr" srvarrPorts.lidarr "sh:lidarr" "/")
  (mkExternal "audiobookshelf" "Audiobookshelf" "https://au.ihar.dev" "sh:audiobookshelf"
    "https://au.ihar.dev"
  )
  (mkInternal "readarr" "Readarr" srvarrPorts.readarr "sh:readarr" "/login")
  (mkInternal "readarr-audio" "Readarr Audio" srvarrPorts.readarrAudio "sh:readarr" "/login")
  (mkInternal "bazarr" "Bazarr" srvarrPorts.bazarr "sh:bazarr" "/")
  (mkInternal "prowlarr" "Prowlarr" srvarrPorts.prowlarr "sh:prowlarr" "/login")
  (mkInternal "transmission" "Transmission" srvarrPorts.transmission "sh:transmission"
    "/transmission/web/"
  )
  (mkInternal "sabnzbd" "SABNZB" srvarrPorts.sabnzbd
    "https://raw.githubusercontent.com/sabnzbd/sabnzbd/70d5134d28a0c1cddff49c97fa013cb67c356f9e/icons/logo-arrow.svg"
    "/login/"
  )
]
