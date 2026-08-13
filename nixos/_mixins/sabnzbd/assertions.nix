{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = model.claim != null;
        message = "host.sabnzbd.storage.claim must select a known storage claim";
      }
      {
        assertion = model.storageGroup != null;
        message = "The selected SABnzbd storage claim must provide a shared group";
      }
      {
        assertion = model.storageGroup == null || model.storageGroup == cfg.group;
        message = "The selected SABnzbd storage claim must use host.sabnzbd.group";
      }
      {
        assertion = model.account != null;
        message = "host.sabnzbd.user must select a registered host account";
      }
      {
        assertion = model.vpnNamespace != null;
        message = "host.sabnzbd.vpn.namespace must select a known VPN namespace";
      }
    ];
  };
}
