{ config, inputs, ... }:
let
  hasAttic = config.host.attic.realmServers != { };
in
{
  imports = [
    inputs.fast-nix-gc.nixosModules.default
    ./builder.nix
    ./builder-observability.nix
  ];

  services.fast-nix-gc = {
    enable = true;
    automatic = true;
    dates = if hasAttic then "*-*-* 03:15:00" else "Sat *-*-* 03:15:00";
  };

  nix.optimise.dates = [ "*-*-* 04:15:00" ];
  nix.optimise.randomizedDelaySec = "5min";

  systemd.services.nix-daemon.serviceConfig = {
    MemoryAccounting = true;
    MemoryMax = "90%";
    OOMScoreAdjust = 500;
  };
}
