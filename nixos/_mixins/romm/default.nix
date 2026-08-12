{ config, lib, ... }:
let
  cfg = config.host.romm;
in
{
  options.host.romm = {
    enable = lib.mkEnableOption "RomM game library";

    publicUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = if cfg.enable then config.host.web.services.romm.public.url else null;
      readOnly = true;
      internal = true;
      description = "Resolved public RomM URL.";
    };
  };
}
