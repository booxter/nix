{ lib, ... }:
rec {
  nix.gc = {
    interval = [
      {
        Hour = 3;
        Minute = 15;
      }
    ];
  };
  # optimise the nix store an hour later
  nix.optimise.interval = lib.lists.forEach nix.gc.interval (e: {
    inherit (e) Minute;
    Hour = e.Hour + 1;
  });
}
