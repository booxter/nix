{
  config,
  lib,
  outputs,
  ...
}:
let
  hostName = config.networking.hostName;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  config.assertions = [
    {
      assertion = !config.host.isProxmox || config.host.network.primaryInterface != null;
      message = "host.isProxmox requires host.network.primaryInterface";
    }
  ]
  ++ lib.optionals config.host.isVM [
    {
      assertion = model.guestNodes.${hostName} != [ ];
      message = "${hostName} references Proxmox cluster '${config.host.proxmox.cluster}' without any nodes in realm '${config.host.realm}'";
    }
  ];
}
