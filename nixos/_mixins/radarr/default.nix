{
  imports = [
    (import ../servarr { name = "radarr"; })
    ./hermes-agent.nix
    ./letterboxd-list.nix
    ./post-processor.nix
  ];
}
