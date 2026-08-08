{ hostInventory, ... }:
{
  services.jellarr = {
    enable = true;
    config = {
      version = 1;
      base_url = "https://${hostInventory.servicesById.jellyfin.publicHost}:443";
      system = {
        serverName = "main";
        libraryScanFanoutConcurrency = 4;
        parallelImageEncodingLimit = 2;
        enableMetrics = true;
        pluginRepositories = [
          {
            name = "Jellyfin Stable";
            url = "https://repo.jellyfin.org/files/plugin/manifest.json";
            enabled = true;
          }
          {
            name = "ThePornDB";
            url = "https://raw.githubusercontent.com/ThePornDatabase/Jellyfin.Plugin.ThePornDB/main/manifest.json";
            enabled = true;
          }
          {
            name = "Letterboxd Link";
            url = "https://raw.githubusercontent.com/zamhedonia/JellyfinLetterboxdLink/master/manifest.json";
            enabled = true;
          }
          {
            name = "Last.fm Stable";
            url = "https://raw.githubusercontent.com/danielfariati/jellyfin-plugin-lastfm/refs/heads/master/manifest.json";
            enabled = true;
          }
        ];
        trickplayOptions = {
          enableHwAcceleration = true;
          enableHwEncoding = true;
          processThreads = 4;
        };
      };
      network.knownProxies = [ "127.0.0.1" ];
      encoding = {
        # TODO: revisit subtitle hardcoding policy once jellarr exposes
        # explicit subtitle-mode/burn-in options declaratively.
        enableHardwareEncoding = true;
        hardwareDecodingCodecs = [
          "h264"
          "hevc"
          "vp9"
          "av1"
        ];
        enableDecodingColorDepth10Hevc = true;
        enableDecodingColorDepth10Vp9 = true;
        allowHevcEncoding = true;
        allowAv1Encoding = false;
      };
      plugins = map (name: { inherit name; }) [
        "AudioDB"
        "Letterboxd Link on Movies"
        "Last.fm"
        "LrcLib Lyrics"
        "MusicBrainz"
        "OMDb"
        "Studio Images"
        "ThePornDB"
        "TheTVDB"
        "TMDb"
      ];
    };
  };
}
