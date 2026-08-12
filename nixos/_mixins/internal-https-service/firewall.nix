{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) enabledServices;
  portsFor =
    service:
    lib.optionals service.openFirewall [
      80
      service.port
    ]
    ++ lib.optionals (service.openFirewall && service.probe.enable) [ service.probe.port ];
in
{
  config = lib.mkIf (enabledServices != { }) {
    networking.firewall.allowedTCPPorts = lib.unique (
      builtins.concatMap portsFor (builtins.attrValues enabledServices)
    );
  };
}
