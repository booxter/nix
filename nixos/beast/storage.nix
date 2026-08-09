{
  host.hardware.storage = {
    mdraid = {
      enable = true;
      # Keep reshape and recovery I/O gentle enough for media serving.
      recoverySpeedLimitMax = 20000;
    };

    smart.enable = true;

    hba.backend = "storcli";

    diskBays = {
      rows = 5;
      columns = 3;
      mapping = [
        {
          bay = 1;
          row = 1;
          column = 1;
          serial = "ZYD01W48";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 3;
          row = 3;
          column = 1;
          serial = "ZYD0CASB";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 5;
          row = 5;
          column = 1;
          serial = "ZYD05Z4J";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 6;
          row = 1;
          column = 2;
          serial = "ZYD041CP";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 7;
          row = 2;
          column = 2;
          serial = "ZXA0RKFF";
          model = "ST24000NM000C-3WD103";
        }
        {
          bay = 9;
          row = 4;
          column = 2;
          serial = "ZXA0B5K4";
          model = "ST24000NM000C-3WD103";
        }
        {
          bay = 10;
          row = 5;
          column = 2;
          serial = "ZXA0FFNN";
          model = "ST24000NM000C-3WD103";
        }
        {
          bay = 11;
          row = 1;
          column = 3;
          serial = "ZYD01W92";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 12;
          row = 2;
          column = 3;
          serial = "ZXA0GW38";
          model = "ST24000NM000C-3WD103";
        }
        {
          bay = 13;
          row = 3;
          column = 3;
          serial = "ZYD02EQQ";
          model = "ST24000NM000H-3KS103";
        }
        {
          bay = 15;
          row = 5;
          column = 3;
          serial = "ZXA0ENE4";
          model = "ST24000NM000C-3WD103";
        }
      ];
      exporter.enable = true;
    };
  };
}
