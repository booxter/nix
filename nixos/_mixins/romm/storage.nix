{ config, lib, ... }:
let
  cfg = config.host.romm;
in
{
  config = lib.mkIf (cfg != null) {
    host.storage.claims.${cfg.storage.claim} = {
      directories =
        builtins.listToAttrs (
          map
            (path: {
              name = "${cfg.storage.relativePath}/${path}";
              value.owner = cfg.user;
            })
            [
              "assets"
              "cache"
              "config"
              "library"
              "library/bios"
              "library/roms"
              "library/roms/pc"
              "resources"
              "sync"
            ]
        )
        // {
          ${cfg.storage.relativePath}.owner = cfg.user;
        };
      attachments.romm-setup = { };
    };
  };
}
