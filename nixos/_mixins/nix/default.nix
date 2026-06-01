{ ... }:
{
  nix.gc.dates = "Mon, 03:15";
  nix.optimise.dates = [ "Mon, 04:15" ];
  nix.optimise.randomizedDelaySec = "5min";

  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };
}
