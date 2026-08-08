{
  kvms.desk = {
    monitors = {
      left.nativeMode = {
        width = 3840;
        height = 2160;
        refreshRate = 60;
      };
      right.nativeMode = {
        width = 3840;
        height = 2160;
        refreshRate = 60;
      };
    };

    layout = {
      left.position = {
        x = 0;
        y = 0;
      };
      right.position = {
        x = 2560;
        y = 0;
      };
    };

    connections = {
      frame = {
        drmCard = "card1";
        scale = 1.5;
        primary = "left";
        connectors = {
          left = "DP-4";
          right = "DP-2";
        };
      };
      mmini = { };
      JGWXHWDL4X = { };
    };
  };
}
