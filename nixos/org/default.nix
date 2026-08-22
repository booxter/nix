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

  host.backups.destination = {
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
      jellyfin = "beast";
      romm = "srvarr";
    };
  };

  host.paperless = {
    storageProvider = "beast";
    gpt = {
      providerHost = "frame";
      textModel = "granite4:32b-a9b-h";
      visionModel = "qwen3-vl:8b-instruct";
    };
  };

  host.vikunja = { };
}
