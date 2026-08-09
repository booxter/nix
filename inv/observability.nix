{
  profiles = {
    capacity = {
      standard = {
        cpu = {
          warningPercent = 80;
          criticalPercent = 90;
        };
        memory = {
          warningPercent = 80;
          criticalPercent = 90;
        };
      };

      cpu-bursty = {
        cpu = null;
        memory = {
          warningPercent = 80;
          criticalPercent = 90;
        };
      };

      interactive = {
        cpu = null;
        memory = null;
      };

      hypervisor = {
        cpu = {
          warningPercent = 80;
          criticalPercent = 90;
        };
        memory = {
          warningAvailableGiB = 16;
          warningPercent = 90;
          criticalAvailableGiB = 8;
          criticalPercent = 95;
        };
      };
    };

    thermal = {
      standard.cpu = true;
      no-cpu.cpu = false;
      none = { };
    };
  };
}
