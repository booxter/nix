{ config, lib }:
let
  cfg = config.host.shelfmark;
  mediaLibraries = import ../media-libraries/model.nix { inherit config lib; };
  downloadModel = import ../downloads/model.nix { inherit config lib; };
  resolveLibrary = name: if name == null then null else mediaLibraries.${name} or null;
  resolveRoute = name: if name == null then null else downloadModel.routes.${name} or null;
in
{
  inherit cfg;
  port = 8084;
  user = "shelfmark";
  group = "media";
  ebooks = resolveLibrary cfg.libraries.ebooks;
  audiobooks = resolveLibrary cfg.libraries.audiobooks;
  torrent = resolveRoute cfg.downloads.torrent;
  usenet = resolveRoute cfg.downloads.usenet;
  ssoApplication = config.host.sso.applications.shelfmark or null;
  shelfmarkService = config.host.web.services.shelfmark;
  oidcClient = config.host.sso.oidc.clients.shelfmark;
  oidcScopes = config.host.sso.oidc.baseScopes;
  audiobookshelfService =
    if config.host.audiobookshelf == null then null else config.host.web.services.audiobookshelf;
  converter = {
    stateDir = "/var/lib/ebook-converter";
    user = "ebook-converter";
    group = "media";
    metricsDir = "/var/lib/prometheus-node-exporter-textfile";
    metricsFile = "/var/lib/prometheus-node-exporter-textfile/ebook-converter.prom";
  };
}
