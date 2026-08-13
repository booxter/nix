{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg;
  servarr = builtins.attrValues model.radarr ++ builtins.attrValues model.sonarr;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.publicHostName != null;
        message = "host.seerr.publicHostName must be set";
      }
      {
        assertion = model.jellyfinHost != null;
        message = "host.seerr.integrations.jellyfin.host must name a known NixOS host";
      }
      {
        assertion = model.jellyfin != null && model.jellyfin.enable;
        message = "host.seerr.integrations.jellyfin.host must run Jellyfin";
      }
      {
        assertion =
          model.jellyfin == null
          || lib.all (
            name: builtins.hasAttr name model.jellyfin.libraries
          ) cfg.integrations.jellyfin.libraries;
        message = "host.seerr.integrations.jellyfin.libraries must select registered Jellyfin libraries";
      }
      {
        assertion = lib.all (instance: instance.api != null) servarr;
        message = "Seerr Servarr integrations must select registered host.web.api entries";
      }
      {
        assertion = lib.all (
          instance: instance.api == null || instance.api.interface == instance.kind
        ) servarr;
        message = "Seerr Servarr integrations must select matching API interfaces";
      }
      {
        assertion = lib.all (instance: instance.media != null) servarr;
        message = "Seerr Servarr integrations must select registered media libraries";
      }
      {
        assertion = cfg.reconcilePackage.seerr == cfg.package;
        message = "Seerr reconciler bindings must derive from services.seerr.package";
      }
    ];
  };
}
