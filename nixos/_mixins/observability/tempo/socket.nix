{
  config,
  lib,
  pkgs,
  ...
}:
let
  paths = import ./paths.nix;
in
{
  options.host.observability.tracing.enable = lib.mkEnableOption "local OTLP trace collection";

  config = lib.mkIf config.host.observability.tracing.enable {
    users.groups.telemetry = { };
    services.alloy.enable = true;
    # A preserved RuntimeDirectory with DynamicUser lives under /run/private,
    # where other services cannot reach it. This shared directory stays put
    # across restarts, including for helpers that already bind-mounted it.
    systemd.tmpfiles.rules = [ "d ${paths.directory} 0770 root telemetry -" ];
    systemd.services.alloy = {
      # Remove a stale socket after an unclean exit.
      preStart = "${pkgs.coreutils}/bin/rm -f ${paths.socket}";
      serviceConfig = {
        Group = "telemetry";
        ReadWritePaths = [ paths.directory ];
        UMask = "0007";
      };
    };
  };
}
