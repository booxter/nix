{
  plugins = {
    polyglot = {
      name = "Polyglot";
      id = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";
    };
    language-tags = {
      name = "Language Tags";
      id = "e6ee25c2-d12c-4382-a48c-66ee9c1c33cb";
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
      id = "a629c0da-fac5-4c7e-931a-7174223f14c8";
    };
    letterboxd = {
      name = "Letterboxd Link on Movies";
      id = "d20f95e1-8b89-7c2b-9e73-43e9f3d29f10";
    };
    lrclib = {
      name = "LrcLib Lyrics";
      id = "d106ebe6-9ca8-4fbc-9cd1-a92a213da9f9";
    };
    musicbrainz = {
      name = "MusicBrainz";
      id = "8c95c4d2-e50c-4fb0-a4f3-6c06ff0f9a1a";
    };
    omdb = {
      name = "OMDb";
      id = "a628c0da-fac5-4c7e-9d1a-7134223f14c8";
    };
    studio-images = {
      name = "Studio Images";
      id = "872a7849-1171-458d-a6fb-3de3d442ad30";
    };
    porndb = {
      name = "ThePornDB";
      id = "fb7580cf-576d-4991-8e56-0b4520c111d3";
    };
    tvdb = {
      name = "TheTVDB";
      id = "a677c0da-fac5-4cde-941a-7134223f14c8";
    };
    tmdb = {
      name = "TMDb";
      id = "b8715ed1-6c47-4528-9ad3-f72deb539cd4";
    };
  };
}
