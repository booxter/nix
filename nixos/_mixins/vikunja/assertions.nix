{ config, lib, ... }:
let
  cfg = config.host.vikunja;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.host.site.timeZone != null;
        message = "Vikunja requires the host site to define an IANA timezone.";
      }
    ];
  };
}
