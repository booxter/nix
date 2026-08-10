{ ... }:
{
  system.stateVersion = 5;

  host.nix.builder.enable = true;

  host.nix.cacheWarmer.enable = true;

  host.network.interfaces.en0.kind = "ethernet";

  host.remote-control = {
    client.enable = true;
    server.vnc.enable = true;
  };

  host.security.smartCard.enable = true;
}
