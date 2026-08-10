{
  host.jellyfin.declarativeConfig = {
    system.pluginRepositories = [
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
}
