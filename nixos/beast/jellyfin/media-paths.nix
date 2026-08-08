{ hostInventory }:
{
  sourceLibraryRoot = "${hostInventory.storage.nfs.exports.media.path}/${hostInventory.storage.nfs.exports.media.layout.library.root}";
  jellyfinLibraryRoot = "/media/library";
}
