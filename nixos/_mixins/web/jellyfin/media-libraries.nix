{
  config,
  hostInventory,
  lib,
  ...
}:
let
  collections = hostInventory.storage.nfs.exports.media.layout.library.collections;
  libraryRoot = hostInventory.storage.nfs.exports.media.layout.library.root;
  collectionPath = name: lib.removePrefix "${libraryRoot}/" collections.${name};
in
{
  config = lib.mkIf config.host.jellyfin.enable {
    services.jellyfin.libraries = [
      {
        name = "Movies";
        path = collectionPath "movies";
        collectionType = "movies";
      }
      {
        name = "Shows";
        path = collectionPath "shows";
        collectionType = "tvshows";
      }
      {
        name = "Family";
        path = collectionPath "family";
        collectionType = "movies";
      }
      {
        name = "Anime";
        path = collectionPath "anime";
        collectionType = "movies";
      }
      {
        name = "Docu";
        path = collectionPath "docu";
        collectionType = "movies";
      }
      {
        name = "Stand-up";
        path = collectionPath "standup";
        collectionType = "movies";
      }
      {
        name = "Attic";
        path = collectionPath "attic";
        collectionType = "movies";
        isAdult = true;
        preferTmdb = true;
      }
      {
        name = "Fruit";
        path = collectionPath "fruit";
        collectionType = "movies";
        isAdult = true;
        preferTmdb = true;
      }
      {
        name = "Fruitsies";
        path = collectionPath "fruitsies";
        collectionType = "tvshows";
        isAdult = true;
      }
      {
        name = "Music";
        path = collectionPath "music";
        collectionType = "music";
      }
    ];
  };
}
