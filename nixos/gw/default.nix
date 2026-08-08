{
  hostInventory,
  ...
}:
let
  freeDns = hostInventory.site.dynamicDns.freeDns;
in
{
  imports = [
    ./qos.nix
    ./wg-home-exporter.nix
  ];

  host.externalService.ddns = {
    enable = true;
    hostname = freeDns.records.gw;
    inherit (freeDns) username;
  };
}
