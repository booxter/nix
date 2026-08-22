{ lib }:
let
  server = name: realm: {
    deviceName = "${lib.strings.toUpper name}-UPS";
    inherit realm;
  };
in
{
  beast = server "beast" "home";
  frame = server "frame" "home";
  nvws = server "nvws" "work";
  prx1-lab = server "prx1-lab" "home";
}
