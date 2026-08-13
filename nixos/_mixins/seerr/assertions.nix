{
  config,
  lib,
  ...
}:
let
  cfg = config.host.seerr;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.publicHostName != null;
        message = "host.seerr.publicHostName must be set";
      }
    ];
  };
}
