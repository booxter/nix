{
  config,
  outputs,
}:
let
  localHost = config.networking.hostName;
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ localHost ];
  byHost =
    builtins.mapAttrs (_: configuration: configuration.config.host.network) otherConfigurations
    // {
      ${localHost} = config.host.network;
    };
  addressFor =
    hostName:
    let
      network = byHost.${hostName} or (throw "unknown NixOS host '${hostName}'");
    in
    if network.ipAddress == null then
      throw "NixOS host '${hostName}' does not declare a site IP reservation"
    else
      network.ipAddress;
in
{
  inherit addressFor byHost;
}
