{
  config,
  lib,
  ...
}:
{
  options.host.hardware.hasTouchId = lib.mkOption {
    type = lib.types.bool;
    default = config.host.hardware.isLaptop;
    defaultText = lib.literalExpression "config.host.hardware.isLaptop";
    description = "Whether the host has Touch ID-backed authentication.";
  };
}
