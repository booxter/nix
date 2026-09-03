{
  imports = [
    (import ../servarr { name = "lidarr"; })
    ./hermes-agent.nix
    ./post-processor.nix
  ];
}
