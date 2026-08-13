{ config, lib, ... }:
let
  model = import ./model.nix { inherit config; };
in
{
  config = lib.mkIf config.host.transmission.enable {
    host.backups.sources.transmission = {
      title = "Transmission";
      paths = [ model.stateDir ];
      exclude = [
        "${model.stateDir}/*.tmp.*"
        "${model.stateDir}/blocklists"
        "${model.stateDir}/blocklists/**"
        "${model.stateDir}/dht.dat"
        "${model.stateDir}/settings.json"
        "${model.stateDir}/stats.json"
      ];
    };
  };
}
