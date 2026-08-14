{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.ups;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  serverName = cfg.client.server;
  server = if serverName == null then null else model.hosts.${serverName} or null;
in
{
  config.assertions = [
    {
      assertion = cfg.server == null || config.nixpkgs.hostPlatform.isLinux;
      message = "only a NixOS host may provide a UPS server";
    }
    {
      assertion = cfg.server == null || serverName == null;
      message = "a host cannot be both a UPS server and a UPS client";
    }
  ]
  ++ lib.optionals (serverName != null) [
    {
      assertion = server != null;
      message = "host.ups.client.server must name a managed host";
    }
    {
      assertion = server != null && server.ups.server != null;
      message = "host.ups.client.server must reference an enabled UPS server";
    }
  ];
}
