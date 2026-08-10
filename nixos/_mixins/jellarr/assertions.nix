{
  config,
  outputs,
  ...
}:
let
  cfg = config.host.jellarr;
  model = import ./model.nix { inherit config outputs; };
in
{
  assertions = [
    {
      assertion = !cfg.enable || model.exists;
      message = "host.jellarr.target.host must name a known NixOS host.";
    }
    {
      assertion = !cfg.enable || model.jellyfinEnabled;
      message = "host.jellarr.target.host must run Jellyfin.";
    }
    {
      assertion = !cfg.enable || cfg.target.url != null;
      message = "Remote Jellarr targets must publish a Jellyfin URL.";
    }
  ];
}
