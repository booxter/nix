{
  repositories = {
    jellyfin-stable = {
      name = "Jellyfin Stable";
      url = "https://repo.jellyfin.org/files/plugin/manifest.json";
      enabled = true;
    };
    porndb = {
      name = "ThePornDB";
      url = "https://raw.githubusercontent.com/ThePornDatabase/Jellyfin.Plugin.ThePornDB/main/manifest.json";
      enabled = true;
    };
    letterboxd = {
      name = "Letterboxd Link";
      url = "https://raw.githubusercontent.com/zamhedonia/JellyfinLetterboxdLink/master/manifest.json";
      enabled = true;
    };
    lastfm = {
      name = "Last.fm Stable";
      url = "https://raw.githubusercontent.com/danielfariati/jellyfin-plugin-lastfm/refs/heads/master/manifest.json";
      enabled = true;
    };
  };
  repositoryOrder = [
    "jellyfin-stable"
    "porndb"
    "letterboxd"
    "lastfm"
  ];

  plugins = {
    audiodb = {
      name = "AudioDB";
      repository = "jellyfin-stable";
    };
    letterboxd = {
      name = "Letterboxd Link on Movies";
      repository = "letterboxd";
    };
    lastfm = {
      name = "Last.fm";
      repository = "lastfm";
    };
    lrclib = {
      name = "LrcLib Lyrics";
      repository = "jellyfin-stable";
    };
    musicbrainz = {
      name = "MusicBrainz";
      repository = "jellyfin-stable";
    };
    omdb = {
      name = "OMDb";
      repository = "jellyfin-stable";
    };
    studio-images = {
      name = "Studio Images";
      repository = "jellyfin-stable";
    };
    porndb = {
      name = "ThePornDB";
      repository = "porndb";
    };
    tvdb = {
      name = "TheTVDB";
      repository = "jellyfin-stable";
    };
    tmdb = {
      name = "TMDb";
      repository = "jellyfin-stable";
    };
  };
  pluginOrder = [
    "audiodb"
    "letterboxd"
    "lastfm"
    "lrclib"
    "musicbrainz"
    "omdb"
    "studio-images"
    "porndb"
    "tvdb"
    "tmdb"
  ];
}
