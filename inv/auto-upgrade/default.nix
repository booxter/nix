{ lib }:
let
  policyLib = import ./lib.nix { inherit lib; };
  inherit (policyLib)
    clock
    daily
    finalize
    weekly
    ;

  policy = rec {
    slotDurationMinutes = 30;
    maintenanceWindow = {
      start = clock 3 30;
      end = clock 5 30;
    };
    phases = {
      builder.upgrade = weekly "Mon" maintenanceWindow.start;
      cache.upgrade = weekly "Mon" (clock 4 0);
      hypervisor.upgrade = weekly "Mon" (clock 4 30);
      workload.upgrade = daily (clock 5 0);
    };
    weeklyReboot = weekly "Sat" (clock 4 30);

    randomizedDelaySec = "0min";
    persistent = false;
    holds = [ ];
  };
in
finalize policy
