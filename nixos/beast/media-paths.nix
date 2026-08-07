{ hostInventory }:
{
  sourceLibraryRoot = "${hostInventory.storage.nfs.exports.media.path}/library";
  jellyfinLibraryRoot = "/media/library";
}
