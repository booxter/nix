{ config, lib, ... }:
{
  options.host.observability.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.host.realm == "home";
    readOnly = true;
    internal = true;
    description = "Whether realm policy enables host-side observability services.";
  };
}
