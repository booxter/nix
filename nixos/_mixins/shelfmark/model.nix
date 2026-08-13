{ config, lib }:
let
  cfg = config.host.shelfmark;
  mediaModel = import ../media-libraries/model.nix { inherit config lib; };
  downloadModel = import ../downloads/model.nix { inherit config lib; };
  resolveLibrary = name: if name == null then null else mediaModel.resolved.${name} or null;
  resolveRoute = name: if name == null then null else downloadModel.routes.${name} or null;
  audiobookLibraryServiceName = cfg.links.audiobookLibraryService;
in
{
  inherit cfg;
  ebooks = resolveLibrary cfg.libraries.ebooks;
  audiobooks = resolveLibrary cfg.libraries.audiobooks;
  torrent = resolveRoute cfg.downloaders.torrent.route;
  usenet = resolveRoute cfg.downloaders.usenet.route;
  ssoApplication = config.host.sso.applications.${cfg.sso.application} or null;
  shelfmarkService = config.host.web.services.shelfmark;
  oidcClient = config.host.sso.oidc.clients.shelfmark;
  oidcScopes = config.host.sso.oidc.baseScopes;
  audiobookLibraryService =
    if audiobookLibraryServiceName == null then
      null
    else
      config.host.web.services.${audiobookLibraryServiceName} or null;
  converter = config.host.ebookConverter;
}
