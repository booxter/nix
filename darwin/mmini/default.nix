{ ... }:
{
  host.observability.client.enable = true;

  imports = [
    ./ups.nix
  ];
}
