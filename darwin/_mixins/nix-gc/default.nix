{ lib, ... }:
rec {
  nix.gc.automatic = true;
  nix.gc.interval = [
    {
      Hour = 3;
      Minute = 15;
      Weekday = 1;
    }
  ];
  # then optimise the nix store an hour later
  nix.optimise.automatic = true;
  nix.optimise.interval = lib.lists.forEach nix.gc.interval (e: {
    inherit (e) Minute Weekday;
    Hour = e.Hour + 1;
  });
}
