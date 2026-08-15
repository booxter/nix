{ ... }:
{
  imports = [ ./builder.nix ];

  nix.gc.dates = "*-*-* 03:15:00";
  nix.optimise.dates = [ "*-*-* 04:15:00" ];
  nix.optimise.randomizedDelaySec = "5min";

  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };
}
