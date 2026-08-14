{
  lib,
  ...
}:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = "25.11";

  host.proxmox.guest = {
    cluster = "lab";
    cores = 4;
    memoryGiB = 16;
    diskGiB = 80;
  };

  host.ups.client.server = "prx1-lab";

  host.backups.destinations.primary = {
    server = "beast";
    publicKey = readPublicKey ./restic.pub;
    # Preserve the existing repository namespace and snapshot history.
    storageName = "orgvm";
  };

  host.degoog = {
    enable = true;
    engines = [
      "brave"
      "brave-images"
      "brave-news"
      "duckduckgo"
      "duckduckgo-images"
      "duckduckgo-news"
      "google"
      "hacker-news"
      "internet-archive"
      "openstreetmap"
      "reddit"
      "stackexchange"
      "wikipedia"
    ];
    features = [
      "brave-autocomplete"
      "definitions"
      "duckduckgo-bangs"
      "github-results"
      "highlight-terms"
      "local-history"
      "math"
      "openstreetmap-results"
      "reddit-results"
      "stocks"
      "time"
      "tmdb-results"
      "weather"
    ];
    theme = "gruvbox";
    integrations = {
      jellyfin.host = "beast";
      romm.host = "srvarr";
    };
  };

  host.paperless = {
    enable = true;
    storage.provider = "beast";
    gpt = {
      enable = true;
      ollama.providerHost = "frame";
      textModel = "granite4:32b-a9b-h";
      visionModel = "qwen3-vl:8b-instruct";
    };
  };

  host.vikunja.enable = true;
}
