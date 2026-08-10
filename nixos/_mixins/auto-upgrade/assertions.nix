{ config, ... }:
let
  reboot = config.host.autoUpgrade.reboot;
in
{
  assertions = [
    {
      assertion = reboot.mode != "scheduled" || reboot.calendar != null;
      message = "host.autoUpgrade.reboot.calendar must be set when reboot.mode is `scheduled`.";
    }
  ];
}
