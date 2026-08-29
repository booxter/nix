{
  # Hosts consume these schedules directly. CI recomputes them from module
  # claims and rejects inventory drift without making each host solve the fleet.
  policy = {
    allowedWindow = {
      start = {
        hour = 3;
        minute = 30;
      };
      end = {
        hour = 6;
        minute = 30;
      };
    };
    dailyAt = {
      hour = 5;
      minute = 15;
    };
    deferredRebootAt = {
      hour = 4;
      minute = 0;
    };
    preferredWeeklyDay = "Mon";
    slotDurationMinutes = 30;
    slotStepMinutes = 40;
    randomizedDelayMinutes = 5;
  };

  schedules = {
    beast = {
      switch = "05:15";
      reboot = {
        mode = "scheduled";
        calendar = "Sat 03:30";
      };
    };
    builder1 = {
      switch = "Mon 03:30";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    builder2 = {
      switch = "Mon 04:10";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    builder3 = {
      switch = "Tue 03:30";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    fana = {
      switch = "04:10";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    frame = {
      switch = "Tue 04:10";
      reboot = {
        mode = "never";
        calendar = null;
      };
    };
    gw = {
      switch = "04:10";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    home = {
      switch = "04:10";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    nv = {
      switch = "05:15";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    nvws = {
      switch = "Mon 03:30";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    org = {
      switch = "04:10";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    pki = {
      switch = "04:10";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    prx1-lab = {
      switch = "Wed 03:30";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    prx2-lab = {
      switch = "Thu 03:30";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    prx3-lab = {
      switch = "Fri 03:30";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
    srvarr = {
      switch = "04:10";
      reboot = {
        mode = "with-upgrade";
        calendar = null;
      };
    };
  };
}
