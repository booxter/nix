{ config, lib, ... }:
let
  cfg = config.host.seerr;
in
{
  config = lib.mkIf (cfg != null) {
    host.web.services.seerr = {
      upstream = "http://127.0.0.1:${toString config.services.seerr.port}";
    };
  };
}
