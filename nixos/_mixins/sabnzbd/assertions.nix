{
  lib,
  sabnzbdModel,
  ...
}:
let
  model = sabnzbdModel;
  inherit (model) cfg;
in
{
  config = lib.mkIf (cfg != null) {
    assertions = [
      {
        assertion = model.claim != null;
        message = "SABnzbd requires the host's 'media' storage claim";
      }
      {
        assertion = model.storageGroup != null;
        message = "The selected SABnzbd storage claim must provide a shared group";
      }
      {
        assertion = model.storageGroup == null || model.storageGroup == "media";
        message = "The selected SABnzbd storage claim must use the media group";
      }
      {
        assertion = model.identity != null;
        message = "SABnzbd requires its shared storage identity";
      }
      {
        assertion = model.vpnNamespace != null;
        message = "SABnzbd requires the 'wg' VPN namespace";
      }
    ];
  };
}
