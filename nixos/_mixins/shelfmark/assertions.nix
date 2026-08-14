{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
in
{
  config.assertions = lib.optionals (cfg != null) [
    {
      assertion = model.ebooks != null && model.ebooks.contentType == "ebooks";
      message = "host.shelfmark.libraries.ebooks must select a registered ebook library";
    }
    {
      assertion = model.audiobooks == null || model.audiobooks.contentType == "audiobooks";
      message = "host.shelfmark.libraries.audiobooks must select a registered audiobook library";
    }
    {
      assertion = model.torrent == null || model.torrent.client.kind == "torrent";
      message = "host.shelfmark.downloads.torrent must select a torrent route";
    }
    {
      assertion = model.usenet == null || model.usenet.client.kind == "usenet";
      message = "host.shelfmark.downloads.usenet must select a usenet route";
    }
    {
      assertion = model.ssoApplication != null;
      message = "Shelfmark requires its realm SSO application";
    }
  ];
}
