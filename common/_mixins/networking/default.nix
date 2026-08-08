{
  config,
  hostSpec,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  isDarwin = lib.hasSuffix "-darwin" hostSpec.platform;
in
{
  config = lib.mkIf config.host.network.manageIdentity (
    if isDarwin then
      { networking.dhcpClientId = hostname; }
    else
      {
        networking.dhcpcd.extraConfig = ''
          clientid ${hostname}
        '';
      }
  );
}
