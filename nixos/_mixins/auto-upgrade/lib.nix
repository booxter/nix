{ lib }:
let
  clockMinutes = clock: clock.hour * 60 + clock.minute;
  formatClock =
    value:
    let
      hour = builtins.div value 60;
      minute = lib.mod value 60;
      pad = part: if part < 10 then "0${toString part}" else toString part;
    in
    "${pad hour}:${pad minute}";
  renderSchedule =
    schedule:
    lib.optionalString (schedule.cadence == "weekly") "${schedule.weekday} "
    + formatClock schedule.start;
  cadenceRank = {
    daily = 0;
    weekly = 1;
    never = 2;
  };
  moreRestrictiveCadence =
    left: right: if cadenceRank.${left} >= cadenceRank.${right} then left else right;
in
{
  inherit
    clockMinutes
    formatClock
    moreRestrictiveCadence
    renderSchedule
    ;
}
