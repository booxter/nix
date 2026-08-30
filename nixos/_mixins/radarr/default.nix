{
  imports = [
    (import ../servarr { name = "radarr"; })
    ./letterboxd-list.nix
    ./multipart-joiner.nix
  ];
}
