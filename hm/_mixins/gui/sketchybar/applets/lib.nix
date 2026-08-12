{ lib }:
{
  mkAppletOptions =
    {
      description,
      defaultEnable ? false,
      defaultPosition,
      defaultOrder,
    }:
    {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = defaultEnable;
        description = "Whether to show ${description} in Sketchybar.";
      };

      position = lib.mkOption {
        type = lib.types.enum [
          "left"
          "center"
          "right"
        ];
        default = defaultPosition;
        description = "Sketchybar section containing ${description}.";
      };

      order = lib.mkOption {
        type = lib.types.int;
        default = defaultOrder;
        description = "Ordering priority for ${description} within its Sketchybar section.";
      };
    };
}
