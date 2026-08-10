# Static media catalog shared by storage provisioning and Jellyfin configuration.
{
  libraries = [
    {
      name = "Movies";
      path = "movies";
      kind = "movies";
    }
    {
      name = "Shows";
      path = "shows";
      kind = "series";
    }
    {
      name = "Family";
      path = "family";
      kind = "movies";
    }
    {
      name = "Anime";
      path = "anime";
      kind = "movies";
    }
    {
      name = "Docu";
      path = "docu";
      kind = "movies";
    }
    {
      name = "Stand-up";
      path = "standup";
      kind = "movies";
    }
    {
      name = "Attic";
      path = "attic";
      kind = "movies";
      audience = "adult";
      metadataPolicy = "tmdb-first";
    }
    {
      name = "Fruit";
      path = "xxx";
      kind = "movies";
      audience = "adult";
      metadataPolicy = "tmdb-first";
    }
    {
      name = "Fruitsies";
      path = "fruitsies";
      kind = "series";
      audience = "adult";
    }
    {
      name = "Music";
      path = "music";
      kind = "music";
    }
  ];
}
