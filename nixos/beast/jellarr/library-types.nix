{ lib }:
{
  isAdult ? false,
  preferTmdb ? false,
}:
[
  (
    {
      type = "Movie";
      metadataFetchers =
        lib.optionals isAdult [
          "ThePornDB Movies"
          "ThePornDB Scenes"
          "ThePornDB JAV"
        ]
        ++ [
          "TheMovieDb"
          "The Open Movie Database"
        ];
      imageFetchers = lib.optionals isAdult [ "ThePornDB" ] ++ [
        "TheMovieDb"
        "The Open Movie Database"
        "Embedded Image Extractor"
        "Screen Grabber"
      ];
    }
    // lib.optionalAttrs (isAdult && preferTmdb) {
      metadataFetcherOrder = [
        "TheMovieDb"
        "ThePornDB Movies"
        "ThePornDB Scenes"
        "ThePornDB JAV"
        "The Open Movie Database"
      ];
      imageFetcherOrder = [
        "TheMovieDb"
        "ThePornDB"
        "The Open Movie Database"
        "Embedded Image Extractor"
        "Screen Grabber"
      ];
    }
  )
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
]
