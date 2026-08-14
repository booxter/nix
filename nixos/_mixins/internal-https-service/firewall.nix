{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) services;
  portsFor =
    service:
    lib.optionals service.openFirewall [
      80
      service.port
    ]
    ++ lib.optionals (service.openFirewall && service.probe != null) [ service.probe.port ];
in
{
  config = lib.mkIf (services != { }) {
    networking.firewall.allowedTCPPorts = lib.unique (
      builtins.concatMap portsFor (builtins.attrValues services)
    );
  };
}
