{
  hostInventory,
  hostSpecName,
  lib,
  ...
}:
let
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};
in
{
  nix.gc.dates = "Mon, 03:15";
  nix.optimise.dates = [ "Mon, 04:15" ];
  nix.optimise.randomizedDelaySec = "5min";

  nix.settings = lib.mkIf (hostSpec.nspawnTestBuilder or false) {
    auto-allocate-uids = true;
    extra-experimental-features = [
      "auto-allocate-uids"
      "cgroups"
    ];
    extra-system-features = [
      "devnet"
      "uid-range"
    ];
    sandbox-paths = [ "/dev/net" ];
  };

  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };
}
