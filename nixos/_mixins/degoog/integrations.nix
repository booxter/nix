{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg jellyfin romm;
in
{
  config = lib.mkIf cfg.enable {
    host.degoog.catalog.features = {
      jellyfin = {
        extension = "plugins/jellyfin";
        secretNames = [ "jellyfin_api_key" ];
        settings.degoog-org-official-extensions-jellyfin-command = {
          apiKey = config.sops.placeholder."degoog/jellyfin_api_key";
          headerName = "X-Emby-Token";
          url = if jellyfin == null then null else jellyfin.publicUrl;
        };
      };

      romm = {
        extension = "plugins/romm";
        secretNames = [ "romm_api_token" ];
        settings.degoog-org-official-extensions-romm-command = {
          apiToken = config.sops.placeholder."degoog/romm_api_token";
          url = if romm == null then null else romm.publicUrl;
        };
      };
    };
  };
}
