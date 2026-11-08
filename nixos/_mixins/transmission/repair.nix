{
  lib,
  pkgs,
  transmissionModel,
  utils,
  ...
}:
let
  model = transmissionModel;
  package = (import ./pkgs pkgs).torrentRepair;
in
{
  config = lib.mkIf (model.cfg != null) {
    systemd.services.transmission-torrent-repair = {
      description = "Verify Transmission torrents reporting corrupt local data";
      after = [
        "nginx.service"
        "transmission.service"
      ];
      wants = [
        "nginx.service"
        "transmission.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = utils.escapeSystemdExecArgs [
          (lib.getExe package)
          "--rpc-url"
          model.rpcUrl
        ];
        User = model.user;
        Group = model.group;
      };
    };

    systemd.timers.transmission-torrent-repair = {
      description = "Periodic Transmission corruption recovery scan";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1h";
        OnUnitActiveSec = "1h";
      };
    };
  };
}
