{
  lib,
  ...
}:
{
  imports = [
    ./prometheus.nix
  ];

  host.observability = {
    nodeExporter = {
      listenAddress = "127.0.0.1";
      mtls.enable = false;
      openFirewall = lib.mkForce false;
    };
  };
}
