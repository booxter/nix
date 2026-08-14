{
  config,
  lib,
  transmissionModel,
  ...
}:
let
  cfg = config.host.transmission;
in
{
  config = lib.mkIf cfg.enable {
    host.downloads.clients.transmission = {
      kind = "torrent";
      implementation = "transmission";
      endpoint = transmissionModel.rpcUrl;
      storageDefaults = {
        owner = cfg.user;
        group = cfg.group;
        mode = "0755";
      };
    };
  };
}
