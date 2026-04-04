{ ... }:
{
  host.observability.client.enable = true;
  host.observability.thermal.enable = true;
  host.observability.lanWan = {
    enable = true;
    interface = "en0";
  };

  imports = [
    ./ups.nix
  ];
}
