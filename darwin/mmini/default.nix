{ ... }:
{
  host.observability.client.enable = true;
  host.observability.client.nodeExporter.mtls.enable = true;
  host.observability.thermal.enable = true;
  host.observability.lanWan = {
    enable = true;
    interface = "en0";
  };

  imports = [
    ./cache-warmup.nix
    ./ups.nix
  ];
}
