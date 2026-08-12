{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg;
  torrentEnvironment = lib.optionalAttrs (model.torrent != null) {
    PROWLARR_TORRENT_CLIENT = model.torrent.client.implementation;
    TRANSMISSION_URL = model.torrent.client.endpoint;
    TRANSMISSION_CATEGORY = model.torrent.label;
    TRANSMISSION_DOWNLOAD_DIR = model.torrent.path;
  };
  usenetEnvironment = lib.optionalAttrs (model.usenet != null) {
    PROWLARR_USENET_CLIENT = model.usenet.client.implementation;
    SABNZBD_URL = model.usenet.client.endpoint;
    SABNZBD_CATEGORY = model.usenet.category;
  };
  converterEnvironment = lib.optionalAttrs cfg.integrations.ebookConverter.enable {
    CUSTOM_SCRIPT = "${model.converter.package}/bin/shelfmark-ebook-converter-hook";
    CUSTOM_SCRIPT_JSON_PAYLOAD = "true";
    CUSTOM_SCRIPT_PATH_MODE = "absolute";
    EBOOK_CONVERTER_LIBRARY_ROOT = model.ebooks.path;
    EBOOK_CONVERTER_STATE_DIR = model.converter.stateDir;
  };
  sabnzbdSecret = if model.usenet == null then null else model.usenet.client.authentication.secret;
in
{
  config = lib.mkIf cfg.enable {
    services.shelfmark.environment = torrentEnvironment // usenetEnvironment // converterEnvironment;

    sops.templates."shelfmark.env" = {
      owner = cfg.user;
      group = cfg.group;
      mode = "0400";
      content = ''
        OIDC_CLIENT_SECRET=${model.oidcClient.secret.placeholder}
      ''
      + lib.optionalString (sabnzbdSecret != null) ''
        SABNZBD_API_KEY=${builtins.getAttr sabnzbdSecret config.sops.placeholder}
      '';
      restartUnits = [ "shelfmark.service" ];
    };
  };
}
