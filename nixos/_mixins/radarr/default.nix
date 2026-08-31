{
  imports = [
    (import ../servarr { name = "radarr"; })
    ./hermes-agent.nix
    ./letterboxd-list.nix
    ./multipart-joiner.nix
  ];
}
