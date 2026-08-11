{
  config,
  lib,
  outputs,
  ...
}:
let
  fleetServices = import ../../../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  publicServices = builtins.filter (
    contribution: contribution.value.public.ingressHost == config.networking.hostName
  ) fleetServices.public;
  helpers = import ./lib.nix { inherit lib; };
  routes = helpers.collect publicServices;
  ports = map (route: route.bandwidthLimit.listenPort) routes;
in
{
  assertions = [
    {
      assertion = builtins.length ports == builtins.length (lib.unique ports);
      message = "public ingress bandwidth-limited routes must use unique HAProxy listen ports";
    }
  ]
  ++ map (route: {
    assertion = lib.hasPrefix "http://" route.upstream;
    message = "public ingress bandwidth-limited route ${route.id} currently requires an HTTP upstream";
  }) routes;
}
