let
  randomizedDelaySec = "5min";
  persistent = false;
  workloadRebootWindow = {
    lower = {
      hour = 4;
      minute = 0;
    };
    upper = {
      hour = 6;
      minute = 0;
    };
  };
in
{
  inherit persistent randomizedDelaySec;

  phases = {
    workload = {
      upgrade = {
        cadence = "daily";
        at = {
          hour = 5;
          minute = 15;
        };
      };
      rebootWindow = workloadRebootWindow;
    };

    builder = {
      upgrade = {
        cadence = "weekly";
        weekday = "Mon";
        at = {
          hour = 3;
          minute = 0;
        };
      };
      # Preserve the current effective window. The old builder definitions
      # attempted to set 02:59, but lost to the default module priority.
      rebootWindow = workloadRebootWindow;
    };

    cache = {
      upgrade = {
        cadence = "weekly";
        weekday = "Mon";
        at = {
          hour = 3;
          minute = 30;
        };
      };
      rebootWindow = {
        lower = {
          hour = 2;
          minute = 59;
        };
        upper = {
          hour = 6;
          minute = 0;
        };
      };
    };

    hypervisor = {
      cadence = "weekly";
      weekday = "Mon";
      defaultAt = {
        hour = 4;
        minute = 0;
      };
      atByHost = {
        prx1-lab = {
          hour = 3;
          minute = 50;
        };
        prx2-lab = {
          hour = 4;
          minute = 20;
        };
        prx3-lab = {
          hour = 4;
          minute = 50;
        };
      };
      rebootWindow = {
        lower = {
          hour = 3;
          minute = 45;
        };
        upper = {
          hour = 6;
          minute = 0;
        };
      };
    };
  };

  cacheHost = "cache";
  manualRebootHosts = [ "frame" ];

  weeklyReboot = {
    weekday = "Sat";
    at = {
      hour = 4;
      minute = 0;
    };
  };

  holds = [
    {
      startDate = "2026-06-08";
      stopDate = "2026-06-28";
    }
  ];
}
