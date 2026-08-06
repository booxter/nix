{
  hostSpec,
  lib,
  ...
}:
{
  nix.gc.dates = "*-*-* 03:15:00";
  nix.optimise.dates = [ "*-*-* 04:15:00" ];
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
    extra-sandbox-paths = [ "/dev/net" ];
  };

  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };
}
