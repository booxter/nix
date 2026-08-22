{
  config,
  lib,
  ...
}:
let
  isoDatePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";
in
{
  assertions = lib.concatMap (hold: [
    {
      assertion = builtins.match isoDatePattern hold.startDate != null;
      message = "host.autoUpgrade.holds startDate `${hold.startDate}` must use YYYY-MM-DD.";
    }
    {
      assertion = builtins.match isoDatePattern hold.stopDate != null;
      message = "host.autoUpgrade.holds stopDate `${hold.stopDate}` must use YYYY-MM-DD.";
    }
    {
      assertion = hold.startDate <= hold.stopDate;
      message = "host.autoUpgrade.holds range `${hold.startDate}..${hold.stopDate}` must not end before it starts.";
    }
  ]) config.host.autoUpgrade.holds;
}
