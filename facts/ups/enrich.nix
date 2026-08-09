{
  hosts,
  lib,
}:
facts:
let
  serverFor =
    hostName:
    let
      host =
        hosts.nixosHosts.${hostName} or (throw "UPS server '${hostName}' references an unknown NixOS host");
      address = host.ipAddress or (throw "UPS server '${hostName}' does not have a stable IPv4 address");
    in
    {
      inherit address hostName;
      name = "${lib.strings.toUpper hostName}-UPS";
    };
in
facts
// {
  serversByName = builtins.listToAttrs (
    map (hostName: {
      name = hostName;
      value = serverFor hostName;
    }) facts.servers
  );
}
