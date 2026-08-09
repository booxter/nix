{
  lib,
}:
raw:
let
  serverFor = hostName: {
    inherit hostName;
    name = "${lib.strings.toUpper hostName}-UPS";
  };
in
raw
// {
  serversByName = builtins.listToAttrs (
    map (hostName: {
      name = hostName;
      value = serverFor hostName;
    }) raw.servers
  );
}
