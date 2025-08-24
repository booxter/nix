{ lib, ... }:
rec {
  nix.gc = {
    interval = [
      {
        Hour = 3;
        Minute = 15;
        Weekday = 1;
      }
    ];
  };
  # optimise the nix store an hour later
  nix.optimise.interval = lib.lists.forEach nix.gc.interval (e: {
    inherit (e) Minute Weekday;
    Hour = e.Hour + 1;
  });
}
