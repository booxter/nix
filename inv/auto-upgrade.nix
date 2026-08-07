let
  randomizedDelaySec = "5min";
  earlyRebootWindow = {
    lower = "02:59";
    upper = "06:00";
  };
in
{
  default = {
    dates = "05:15";
    inherit randomizedDelaySec;
    persistent = false;
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "06:00";
    };
  };

  builder = {
    dates = "Mon 03:00";
    rebootWindow = earlyRebootWindow;
  };

  cache = {
    dates = "Mon 03:30";
    inherit randomizedDelaySec;
    rebootWindow = earlyRebootWindow;
  };

  proxmox = {
    defaultDates = "Mon 04:00";
    datesByHost = {
      prx1-lab = "Mon 03:50";
      prx2-lab = "Mon 04:20";
      prx3-lab = "Mon 04:50";
    };
    rebootWindow.lower = "03:45";
  };

  critical = {
    allowReboot = false;
    rebootWindow = null;
    weeklyReboot = {
      dates = "Sat 04:00";
      inherit randomizedDelaySec;
      persistent = false;
    };
  };

  hosts.frame.allowReboot = false;

  holds = [
    {
      startDate = "2026-06-08";
      stopDate = "2026-06-28";
    }
  ];
}
