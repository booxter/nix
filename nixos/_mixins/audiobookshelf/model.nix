{ config, lib }:
let
  cfg = config.host.audiobookshelf;
  mediaModel = import ../media-libraries/model.nix { inherit config lib; };
  resolveLibrary = source: library: {
    inherit source;
    inherit (library)
      access
      displayName
      icon
      provider
      ;
    media = mediaModel.resolved.${source} or null;
  };
in
{
  inherit cfg;
  port = 9292;
  user = "audiobookshelf";
  group = "media";
  libraries = lib.mapAttrs resolveLibrary cfg.libraries;
  ssoApplication = config.host.sso.applications.audiobookshelf or null;
  service = config.host.web.services.audiobookshelf;
  oidcClient = config.host.sso.oidc.clients.audiobookshelf;
  oidcScopes = config.host.sso.oidc.baseScopes;
}
