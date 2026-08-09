{
  facts,
  lib,
}:
raw:
let
  hosts = facts.hosts;
  serverFor =
    hostName:
    let
      host =
        hosts.nixos.${hostName} or (throw "UPS server '${hostName}' references an unknown NixOS host");
      address = host.ipAddress or (throw "UPS server '${hostName}' does not have a stable IPv4 address");
    in
    {
      inherit address hostName;
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
