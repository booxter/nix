{
  blackboxHttpMtlsTlsConfig,
  config,
  grafanaPort,
  hostInventory,
  lib,
  outputs,
  prometheusMtlsTlsConfig,
}:
let
  services = import ./services.nix {
    inherit
      blackboxHttpMtlsTlsConfig
      config
      grafanaPort
      hostInventory
      lib
      outputs
      ;
  };
  network = import ./network.nix {
    inherit
      config
      hostInventory
      lib
      outputs
      prometheusMtlsTlsConfig
      ;
  };
in
{
  inherit (network) assertions;
  inherit (services) usesHttpMtls;

  modules = services.modules // network.modules;
  scrapeConfigs = services.scrapeConfigs ++ network.scrapeConfigs;
}
