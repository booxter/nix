{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.sso.provider;
  package = pkgs.callPackage ./packages/kanidm-tools/reset-credentials {
    defaultTarget = cfg.host;
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ package ];
  };
}
