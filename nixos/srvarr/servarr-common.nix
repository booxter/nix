{ config, lib }:
let
  commonSettings = {
    auth = {
      method = "External";
      required = "Enabled";
    };
    log.analyticsEnabled = false;
    server.bindaddress = "127.0.0.1";
    update = {
      automatically = false;
      mechanism = "external";
    };
  };
in
{
  mkServarrService =
    {
      name,
      extraSettings ? { },
    }:
    let
      serviceCfg = lib.getAttr name config.services;
    in
    {
      services.${name} = {
        enable = true;
        settings = lib.recursiveUpdate commonSettings extraSettings;
      };

      host.web.services.${name} = {
        enable = true;
        upstream = "http://127.0.0.1:${toString serviceCfg.settings.server.port}";
        health = {
          frontend = {
            enable = true;
            path = "/oauth2/sign_in";
          };
          backend = {
            enable = true;
            path = "/ping";
          };
        };
        dashboard = {
          enable = true;
          section = "media-admin";
        };
      };
    };
}
