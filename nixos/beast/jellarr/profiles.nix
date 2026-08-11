{ lib }:
let
  movieType =
    {
      audience,
      metadataPolicy,
      ...
    }:
    let
      adult = audience == "adult";
    in
    {
      type = "Movie";
      metadataFetchers =
        lib.optionals adult [
          "ThePornDB Movies"
          "ThePornDB Scenes"
          "ThePornDB JAV"
        ]
        ++ [
          "TheMovieDb"
          "The Open Movie Database"
        ];
      imageFetchers = lib.optionals adult [ "ThePornDB" ] ++ [
        "TheMovieDb"
        "The Open Movie Database"
        "Embedded Image Extractor"
        "Screen Grabber"
      ];
    }
    // lib.optionalAttrs (metadataPolicy == "tmdb-first") {
      metadataFetcherOrder = [
        "TheMovieDb"
      ]
      ++ lib.optionals adult [
        "ThePornDB Movies"
        "ThePornDB Scenes"
        "ThePornDB JAV"
      ]
      ++ [ "The Open Movie Database" ];
      imageFetcherOrder = [
        "TheMovieDb"
      ]
      ++ lib.optionals adult [ "ThePornDB" ]
      ++ [
        "The Open Movie Database"
        "Embedded Image Extractor"
        "Screen Grabber"
      ];
    };
in
{
  kinds = {
    movies = {
      collectionType = "movies";
      requiredPlugins = [
        "letterboxd"
        "omdb"
        "studio-images"
        "tmdb"
      ];
    };
    series = {
      collectionType = "tvshows";
      requiredPlugins = [
        "omdb"
        "studio-images"
        "tvdb"
        "tmdb"
      ];
    };
    music = {
      collectionType = "music";
      requiredPlugins = [
        "audiodb"
        "lastfm"
        "lrclib"
        "musicbrainz"
      ];
    };
  };

  audiences = {
    general.requiredPlugins = [ ];
    adult.requiredPlugins = [ "porndb" ];
  };

  typeOptions = library: [
    (movieType library)
    {
      type = "Series";
      metadataFetchers = [
        "Missing Episode Fetcher"
        "TheTVDB"
        "TheMovieDb"
        "The Open Movie Database"
      ];
      imageFetchers = [
        "TheTVDB"
        "TheMovieDb"
      ];
    }
    {
      type = "Season";
      metadataFetchers = [
        "TheTVDB"
        "TheMovieDb"
      ];
      imageFetchers = [
        "TheTVDB"
        "TheMovieDb"
      ];
    }
    {
      type = "Episode";
      metadataFetchers = [
        "TheTVDB"
        "TheMovieDb"
        "The Open Movie Database"
      ];
      imageFetchers = [
        "TheTVDB"
        "TheMovieDb"
        "The Open Movie Database"
        "Embedded Image Extractor"
        "Screen Grabber"
      ];
    }
    {
      type = "MusicArtist";
      metadataFetchers = [ "MusicBrainz" ];
      imageFetchers = [ "TheAudioDB" ];
    }
    {
      type = "MusicAlbum";
      metadataFetchers = [ "MusicBrainz" ];
      imageFetchers = [ "TheAudioDB" ];
    }
    {
      type = "Audio";
      metadataFetchers = [ ];
      imageFetchers = [ "Image Extractor" ];
    }
    {
      type = "MusicVideo";
      metadataFetchers = [ ];
      imageFetchers = [
        "Embedded Image Extractor"
        "Screen Grabber"
      ];
    }
  ];
}
