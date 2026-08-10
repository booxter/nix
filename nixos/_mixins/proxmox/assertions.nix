{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.proxmox;
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
    {
      assertion = config.host.isProxmox == (cfg.node.cluster != null);
      message = "${hostName} must declare host.proxmox.node.cluster exactly when it is a Proxmox node";
    }
    {
      assertion = config.host.isVM == (cfg.guest.cluster != null);
      message = "${hostName} must declare host.proxmox.guest.cluster exactly when it is a VM";
    }
  ]
  ++ lib.optionals (cfg.guest.cluster != null) [
    {
      assertion = model.guestNodes.${hostName} != [ ];
      message = "${hostName} references Proxmox cluster '${cfg.guest.cluster}' without any nodes";
    }
  ];
}
