{
  repositories = {
    polyglot = {
      name = "Polyglot";
      url = "https://raw.githubusercontent.com/Maronato/jellyfin-plugin-polyglot/main/manifest.json";
      enabled = true;
    };
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
    language-tags = {
      name = "Language Tags";
      url = "https://raw.githubusercontent.com/TheXaman/jellyfin-plugin-languageTags/main/manifest.json";
      enabled = true;
    };
  };
  plugins = {
    polyglot = {
      name = "Polyglot";
      repository = "polyglot";
    };
    language-tags = {
      name = "Language Tags";
      repository = "language-tags";
      configuration = {
        # Parallel episode updates can time out on Jellyfin's SQLite write lock.
        # https://github.com/TheXaman/jellyfin-plugin-languageTags/issues/40
        SynchronousRefresh = true;
        # Jellyfin applies allowed-tag filters to people and music as well as videos.
        EnableNonMediaTagging = true;
        NonMediaItemTypes = "Person,Audio,MusicAlbum,MusicArtist,MusicGenre";
        NonMediaTag = "non_media";
      };
    };
    audiodb = {
      name = "AudioDB";
      repository = "jellyfin-stable";
    };
    letterboxd = {
      name = "Letterboxd Link on Movies";
      repository = "letterboxd";
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
}
