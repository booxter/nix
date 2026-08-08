{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.wireguardEndpoint;
  endpoint = hostInventory.site.wireguard.${cfg.name};
  freeDns = hostInventory.site.dynamicDns.freeDns;
  recordName = endpoint.gateway.dynamicDnsRecord;
in
{
  config = lib.mkIf (cfg.name != null) {
    assertions = [
      {
        assertion = builtins.hasAttr recordName freeDns.records;
        message = "WireGuard endpoint ${cfg.name} references unknown dynamic DNS record ${recordName}";
      }
    ];

    host.externalService.ddns = {
      enable = true;
      hostname = freeDns.records.${recordName};
      inherit (freeDns) username;
    };
  };
}
