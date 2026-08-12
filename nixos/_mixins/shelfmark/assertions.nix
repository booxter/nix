{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
in
{
  config.assertions = lib.optionals cfg.enable [
    {
      assertion = cfg.publicHostName != null;
      message = "host.shelfmark.publicHostName must be set";
    }
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
      message = "host.shelfmark.downloaders.torrent.route must select a torrent route";
    }
    {
      assertion = model.usenet == null || model.usenet.client.kind == "usenet";
      message = "host.shelfmark.downloaders.usenet.route must select a usenet route";
    }
    {
      assertion = model.ssoApplication != null;
      message = "host.shelfmark.sso.application must select a realm SSO application";
    }
    {
      assertion = model.audiobookLibraryService == null || model.audiobookLibraryService.public.enable;
      message = "host.shelfmark.presentation.audiobookLibraryService must select a public web service";
    }
    {
      assertion = !cfg.integrations.ebookConverter.enable || config.host.ebookConverter.enable;
      message = "Shelfmark's ebook converter integration requires host.ebookConverter.enable";
    }
    {
      assertion =
        !cfg.integrations.ebookConverter.enable
        || config.host.ebookConverter.library == cfg.libraries.ebooks;
      message = "Shelfmark and the ebook converter must select the same ebook library";
    }
  ];
}
